// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_find_bar_and_toasts.h"

#include <algorithm>
#include <utility>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/strings/string_number_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "build/build_config.h"
#include "cc/paint/paint_flags.h"
#include "components/find_in_page/find_notification_details.h"
#include "components/find_in_page/find_types.h"
#include "content/public/browser/web_contents.h"
#include "open_unified/ui/design/open_glyphs.h"
#include "open_unified/ui/design/open_motion.h"
#include "third_party/skia/include/core/SkRRect.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/compositor/layer.h"
#include "ui/events/event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/geometry/rect_conversions.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/skia_conversions.h"
#include "ui/gfx/geometry/transform.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/border.h"
#include "ui/views/controls/textfield/textfield.h"
#include "ui/views/widget/widget.h"

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
                                if (self->target_) {
                                  self->FindInTarget(false);
                                } else if (self->delegate_) {
                                  self->delegate_->OnFindNext(false);
                                }
                              },
                              base::Unretained(this)));
  next_ = make_button(Glyph::kChevronDown, u"Next",
                      base::BindRepeating(
                          [](OpenFindBarView* self) {
                            if (self->target_) {
                              self->FindInTarget(true);
                            } else if (self->delegate_) {
                              self->delegate_->OnFindNext(true);
                            }
                          },
                          base::Unretained(this)));
  close_ = make_button(
      Glyph::kClose, u"Close",
      base::BindRepeating(&OpenFindBarView::Close, base::Unretained(this)));
  auto toggle = std::make_unique<PaintedButton>(
      base::BindRepeating(
          [](OpenFindBarView* self) {
            self->SetCaseSensitive(!self->case_sensitive_);
          },
          base::Unretained(this)),
      base::BindRepeating(&OpenFindBarView::PaintCaseToggle,
                          base::Unretained(this)),
      u"Match Case");
  toggle->SetVisible(false);
  case_toggle_ = AddChildView(std::move(toggle));
  SetAppearance(appearance_);
  UpdateButtons();
}

OpenFindBarView::~OpenFindBarView() {
  // Leave no highlights behind on a page that outlives the bar.
  StopFinding();
  field_->set_controller(nullptr);
}

find_in_page::FindTabHelper* OpenFindBarView::target_helper() const {
  return target_ ? find_in_page::FindTabHelper::FromWebContents(target_)
                 : nullptr;
}

void OpenFindBarView::SetTarget(content::WebContents* contents) {
  if (contents == target_) {
    return;
  }
  StopFinding();
  find_observation_.Reset();
  target_ = contents;
  if (find_in_page::FindTabHelper* helper = target_helper()) {
    find_observation_.Observe(helper);
  } else {
    target_ = nullptr;  // A page without find support: delegate mode.
  }
  ClearResult();
  // The same query searches the new page (Peek opened over the tab, the
  // focus moved to another Split pane).
  if (target_ && !field_->GetText().empty()) {
    FindInTarget(/*forward=*/true);
  }
}

void OpenFindBarView::SetCaseSensitive(bool case_sensitive) {
  if (case_sensitive_ == case_sensitive) {
    return;
  }
  case_sensitive_ = case_sensitive;
  case_toggle_->GetViewAccessibility().SetCheckedState(
      case_sensitive_ ? ax::mojom::CheckedState::kTrue
                      : ax::mojom::CheckedState::kFalse);
  case_toggle_->SchedulePaint();
  if (target_ && !field_->GetText().empty()) {
    FindInTarget(/*forward=*/true);
  } else if (delegate_ && !field_->GetText().empty()) {
    delegate_->OnFindQueryChanged(std::u16string(field_->GetText()));
  }
}

void OpenFindBarView::SetShowsCaseToggle(bool shows) {
  shows_case_toggle_ = shows;
  case_toggle_->SetVisible(shows);
  InvalidateLayout();
  SchedulePaint();
}

void OpenFindBarView::StopFinding() {
  if (find_in_page::FindTabHelper* helper = target_helper()) {
    // kKeep turns the active match into a normal selection and removes every
    // highlight, as Chromium's own find bar does on close.
    helper->StopFinding(find_in_page::SelectionAction::kKeep);
  }
}

void OpenFindBarView::FindInTarget(bool forward) {
  find_in_page::FindTabHelper* helper = target_helper();
  if (!helper) {
    return;
  }
  const std::u16string text(field_->GetText());
  if (text.empty()) {
    helper->StopFinding(find_in_page::SelectionAction::kClear);
    ClearResult();
    return;
  }
  // The same text and case with find_match continues the session (next /
  // previous); other text, another case or another page starts a new one
  // (FindTabHelper::StartFinding).
  helper->StartFinding(text, forward, case_sensitive_, /*find_match=*/true);
}

void OpenFindBarView::OnFindResultAvailable(
    content::WebContents* web_contents) {
  find_in_page::FindTabHelper* helper = target_helper();
  if (!helper || web_contents != target_) {
    return;
  }
  if (field_->GetText().empty()) {
    ClearResult();
    return;
  }
  const find_in_page::FindNotificationDetails& result = helper->find_result();
  if (result.number_of_matches() < 0) {
    return;  // The renderer has not counted yet.
  }
  SetResult(std::max(0, result.active_match_ordinal()),
            result.number_of_matches());
}

void OpenFindBarView::OnFindTabHelperDestroyed(
    find_in_page::FindTabHelper* helper) {
  find_observation_.Reset();
  target_ = nullptr;
  ClearResult();
  if (delegate_) {
    delegate_->OnFindTargetDestroyed();
  }
}

void OpenFindBarView::PaintCaseToggle(gfx::Canvas* canvas,
                                      const gfx::Rect& bounds,
                                      bool hovered) {
  const SkColor tint = appearance_.dark ? kInputTextDark : kInputTextLight;
  if (case_sensitive_ || hovered) {
    secondary::FillRoundRect(
        canvas, gfx::RectF(bounds), 4.f,
        case_sensitive_
            ? secondary::WithAlpha(appearance_.ActiveAccent(), 0.85f)
            : secondary::WithAlpha(
                  appearance_.dark ? SK_ColorWHITE : SK_ColorBLACK, 0.07f));
  }
  secondary::DrawText(canvas, u"Aa",
                      secondary::FontOfSize(12, gfx::Font::Weight::SEMIBOLD),
                      case_sensitive_ ? SK_ColorWHITE : tint, bounds,
                      gfx::Canvas::TEXT_ALIGN_CENTER);
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
    if (target_) {
      FindInTarget(/*forward=*/true);
    } else if (delegate_) {
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
  // Arc draws "3/14" (page-chrome.md §1: ordinal, "/", total); assistive
  // tech hears "3 of 14".
  GetViewAccessibility().SetDescription(
      result_type_ == ResultType::kResults
          ? base::NumberToString16(active_ordinal) + u" of " +
                base::NumberToString16(total)
          : (result_type_ == ResultType::kNoResults ? u"Not Found"
                                                    : std::u16string()));
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

bool OpenFindBarView::HasCompositionText() const {
  return field_ && field_->HasCompositionText();
}

void OpenFindBarView::SetAppearance(const secondary::Appearance& appearance) {
  appearance_ = appearance;
  const SkColor tint = appearance_.dark ? kInputTextDark : kInputTextLight;
  for (GlyphButton* button : {previous_.get(), next_.get(), close_.get()}) {
    button->SetGlyphColor(tint);
    button->SetHoverFill(secondary::WithAlpha(
        appearance_.dark ? SK_ColorWHITE : SK_ColorBLACK, 0.07f));
  }
  if (case_toggle_) {
    case_toggle_->SchedulePaint();
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
    width = std::max(0, std::min(width, available_size.width().value() -
                                            GetInsets().width()));
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
  if (shows_case_toggle_) {
    // Open's optional "Aa" sits left of the separator (no Arc control).
    constexpr int kToggleWidth = 26;
    case_toggle_->SetBoundsRect(gfx::Rect(separator_x_ - 2 - kToggleWidth,
                                          button_y, kToggleWidth, button));
    results_left = case_toggle_->x();
  }
  const int results_right = results_left;
  count_rect_ = gfx::Rect();
  const gfx::FontList count_font = secondary::FontOfSize(kCountFontSize);
  if (result_type_ == ResultType::kResults) {
    next_->SetBoundsRect(
        gfx::Rect(results_right - 2 - button, button_y, button, button));
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
    count_rect_ =
        gfx::Rect(results_right - 6 - w, inner.y(), w, inner.height());
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
  if (target_) {
    FindInTarget(/*forward=*/true);
    return;
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
      if (field_->GetText().empty()) {
        return true;
      }
      if (target_) {
        FindInTarget(!event.IsShiftDown());
      } else if (delegate_) {
        delegate_->OnFindNext(!event.IsShiftDown());
      }
      return true;
    default:
      return false;
  }
}

void OpenFindBarView::Close() {
  // Highlights clear on close in both modes when the bar owns the session.
  StopFinding();
  ClearResult();
  if (delegate_) {
    delegate_->OnFindClosed();
  }
}

BEGIN_METADATA(OpenFindBarView)
END_METADATA

// ===========================================================================
// Toasts.
// ===========================================================================

namespace {

// Motion (Motion.swift): grow from 0.3 at the top center with the toastIn
// spring while fading in linearly over 0.12 s; leave by shrinking back
// toward the top center and fading out in 0.16 s. Older toasts slide down
// with the same spring.
constexpr double kToastInScale = 0.3;
constexpr double kToastOutScale = 0.3;
constexpr motion::CubicCurve kToastOutCurve{0.42, 0.0, 1.0, 1.0};
constexpr motion::CubicCurve kLinearCurve{0.0, 0.0, 1.0, 1.0};

std::vector<std::u16string> CaptureHintKeycaps() {
#if BUILDFLAG(IS_MAC)
  return {u"⌘", u"⇧"};
#else
  return {u"Ctrl", u"Shift"};
#endif
}

void SetUndoButton(ToastSpec& spec, base::OnceClosure undo) {
  spec.button_label = u"Undo";
  spec.button_glyph = Glyph::kUndo;
  spec.button_symbol_name = "arrow.uturn.backward";
  spec.button_action = std::move(undo);
  spec.lifetime = toast_metrics::kUndoLifetime;
}

void SetTextButton(ToastSpec& spec,
                   std::u16string label,
                   base::OnceClosure action) {
  if (!action) {
    return;  // No handler: no dead button.
  }
  spec.button_label = std::move(label);
  spec.button_action = std::move(action);
}

}  // namespace

std::string_view OpenToastKindName(OpenToastKind kind) {
  switch (kind) {
    case OpenToastKind::kCustom:
      return "custom";
    case OpenToastKind::kCopiedUrl:
      return "copied-url";
    case OpenToastKind::kCopiedCleanLink:
      return "copied-clean-link";
    case OpenToastKind::kCopiedCleanLinks:
      return "copied-clean-links";
    case OpenToastKind::kCopiedMarkdown:
      return "copied-markdown";
    case OpenToastKind::kCopiedQuoteLink:
      return "copied-quote-link";
    case OpenToastKind::kCopied:
      return "copied";
    case OpenToastKind::kCopiedImage:
      return "copied-image";
    case OpenToastKind::kCopiedEaselUrl:
      return "copied-easel-url";
    case OpenToastKind::kCopiedOpenInfo:
      return "copied-open-info";
    case OpenToastKind::kTabArchived:
      return "tab-archived";
    case OpenToastKind::kClosedWindow:
      return "closed-window";
    case OpenToastKind::kTabRestored:
      return "tab-restored";
    case OpenToastKind::kTabReset:
      return "tab-reset";
    case OpenToastKind::kTabPinned:
      return "tab-pinned";
    case OpenToastKind::kTabUnpinned:
      return "tab-unpinned";
    case OpenToastKind::kAddedToFavorites:
      return "added-to-favorites";
    case OpenToastKind::kRemovedFromFavorites:
      return "removed-from-favorites";
    case OpenToastKind::kClearedTabs:
      return "cleared-tabs";
    case OpenToastKind::kArchiveCleared:
      return "archive-cleared";
    case OpenToastKind::kFolderDeleted:
      return "folder-deleted";
    case OpenToastKind::kTabsNotSaved:
      return "tabs-not-saved";
    case OpenToastKind::kSplitViewAdded:
      return "split-view-added";
    case OpenToastKind::kSplitViewClosed:
      return "split-view-closed";
    case OpenToastKind::kSpaceSwitched:
      return "space-switched";
    case OpenToastKind::kSpaceCreated:
      return "space-created";
    case OpenToastKind::kSpaceDeleted:
      return "space-deleted";
    case OpenToastKind::kProfileSwitched:
      return "profile-switched";
    case OpenToastKind::kPeekClosed:
      return "peek-closed";
    case OpenToastKind::kPeekPromoted:
      return "peek-promoted";
    case OpenToastKind::kSentToLittleOpen:
      return "sent-to-little-open";
    case OpenToastKind::kExtensionInstalled:
      return "extension-installed";
    case OpenToastKind::kExtensionLoadFailed:
      return "extension-load-failed";
    case OpenToastKind::kExtensionPinned:
      return "extension-pinned";
    case OpenToastKind::kExtensionUnpinned:
      return "extension-unpinned";
    case OpenToastKind::kBoostApplied:
      return "boost-applied";
    case OpenToastKind::kBoostDisabled:
      return "boost-disabled";
    case OpenToastKind::kBoostFailed:
      return "boost-failed";
    case OpenToastKind::kZapSaved:
      return "zap-saved";
    case OpenToastKind::kAdBlockEnabled:
      return "adblock-enabled";
    case OpenToastKind::kAdBlockPaused:
      return "adblock-paused";
    case OpenToastKind::kAdBlockSaveFailed:
      return "adblock-save-failed";
    case OpenToastKind::kSiteDataClearFailed:
      return "site-data-clear-failed";
    case OpenToastKind::kDownloadStarted:
      return "download-started";
    case OpenToastKind::kDownloadCompleted:
      return "download-completed";
    case OpenToastKind::kDownloadFailed:
      return "download-failed";
    case OpenToastKind::kCaptureInProgress:
      return "capture-in-progress";
    case OpenToastKind::kCaptureSaved:
      return "capture-saved";
    case OpenToastKind::kCaptureHint:
      return "capture-hint";
    case OpenToastKind::kPageTranslated:
      return "page-translated";
    case OpenToastKind::kZoom:
      return "zoom";
    case OpenToastKind::kDeveloperModeOn:
      return "developer-mode-on";
    case OpenToastKind::kDeveloperModeOff:
      return "developer-mode-off";
    case OpenToastKind::kEaselSaved:
      return "easel-saved";
    case OpenToastKind::kNoteSaved:
      return "note-saved";
    case OpenToastKind::kSyncCompleted:
      return "sync-completed";
    case OpenToastKind::kSyncConflict:
      return "sync-conflict";
    case OpenToastKind::kSyncFailed:
      return "sync-failed";
    case OpenToastKind::kInfo:
      return "info";
    case OpenToastKind::kWarning:
      return "warning";
    case OpenToastKind::kError:
      return "error";
  }
  return "custom";
}

ToastSpec::ToastSpec() = default;
ToastSpec::ToastSpec(ToastSpec&&) = default;
ToastSpec& ToastSpec::operator=(ToastSpec&&) = default;
ToastSpec::~ToastSpec() = default;

// static
ToastSpec ToastSpec::ForKind(OpenToastKind kind,
                             std::u16string detail,
                             base::OnceClosure action) {
  ToastSpec spec;
  spec.kind = kind;
  auto set = [&spec](std::u16string title, Glyph glyph, const char* symbol) {
    spec.title = std::move(title);
    spec.glyph = glyph;
    spec.symbol_name = symbol ? symbol : "";
  };
  auto with_detail = [&detail](const char16_t* prefix,
                               const char16_t* fallback) {
    return detail.empty() ? std::u16string(fallback)
                          : std::u16string(prefix) + detail;
  };
  switch (kind) {
    case OpenToastKind::kCustom:
      spec.title = detail;
      break;
    // Copy.
    case OpenToastKind::kCopiedUrl:
      set(u"Copied Current URL", Glyph::kLink, "link");
      break;
    case OpenToastKind::kCopiedCleanLink:
      set(u"Copied a clean link without trackers", Glyph::kLink, "link");
      break;
    case OpenToastKind::kCopiedCleanLinks:
      set(u"Copied clean links without trackers", Glyph::kLink, "link");
      break;
    case OpenToastKind::kCopiedMarkdown:
      set(u"Copied URL as Markdown", Glyph::kCopy, "doc.on.doc");
      break;
    case OpenToastKind::kCopiedQuoteLink:
      set(u"Copied Quote Link", Glyph::kLink, "quote.bubble.fill");
      break;
    case OpenToastKind::kCopied:
      set(u"Copied", Glyph::kCopy, "doc.on.doc");
      break;
    case OpenToastKind::kCopiedImage:
      set(u"Copied Image", Glyph::kCapture, "photo");
      break;
    case OpenToastKind::kCopiedEaselUrl:
      set(u"Copied Easel URL", Glyph::kLink, "link");
      break;
    case OpenToastKind::kCopiedOpenInfo:
      set(u"Copied Open Info", Glyph::kCopy, "doc.on.doc");
      break;
    // Tabs and windows.
    case OpenToastKind::kTabArchived:
      set(u"Tab Archived", Glyph::kCheck, "archivebox");
      if (action) {
        SetUndoButton(spec, std::move(action));
      }
      break;
    case OpenToastKind::kClosedWindow:
      set(u"Window Closed", Glyph::kClose, "macwindow");
      if (action) {
        SetUndoButton(spec, std::move(action));
      }
      break;
    case OpenToastKind::kTabRestored:
      set(u"Tab Restored", Glyph::kUndo, "arrow.uturn.backward");
      break;
    case OpenToastKind::kTabReset:
      set(u"Tab Reset", Glyph::kReload, "arrow.counterclockwise");
      break;
    case OpenToastKind::kTabPinned:
      set(u"Tab Pinned", Glyph::kCheck, "pin.fill");
      break;
    case OpenToastKind::kTabUnpinned:
      set(u"Tab Unpinned", Glyph::kCheck, "pin.slash");
      break;
    case OpenToastKind::kAddedToFavorites:
      set(u"Added to Favorites", Glyph::kCheck, "star.fill");
      break;
    case OpenToastKind::kRemovedFromFavorites:
      set(u"Removed from Favorites", Glyph::kCheck, "star.slash");
      break;
    case OpenToastKind::kClearedTabs:
      set(u"Cleared Tabs", Glyph::kTrash, "trash");
      if (action) {
        SetUndoButton(spec, std::move(action));
      }
      break;
    case OpenToastKind::kArchiveCleared:
      set(u"Archive Cleared", Glyph::kTrash, "trash");
      break;
    case OpenToastKind::kFolderDeleted:
      set(u"Folder deleted", Glyph::kTrash, "trash");
      if (action) {
        SetUndoButton(spec, std::move(action));
      }
      break;
    case OpenToastKind::kTabsNotSaved:
      set(u"Your tabs could not be saved", Glyph::kNone,
          "exclamationmark.triangle.fill");
      spec.subtitle = detail;
      break;
    case OpenToastKind::kSplitViewAdded:
      set(u"Added to Split View", Glyph::kSplit, "rectangle.split.2x1");
      break;
    case OpenToastKind::kSplitViewClosed:
      set(u"Split View Closed", Glyph::kSeparate, "rectangle");
      if (action) {
        SetUndoButton(spec, std::move(action));
      }
      break;
    // Spaces and Profiles.
    case OpenToastKind::kSpaceSwitched:
      spec.title = detail;
      break;
    case OpenToastKind::kSpaceCreated:
      set(with_detail(u"Created ", u"Space Created"), Glyph::kPlus,
          "plus.square.on.square");
      break;
    case OpenToastKind::kSpaceDeleted:
      set(with_detail(u"Deleted ", u"Space Deleted"), Glyph::kTrash, "trash");
      if (action) {
        SetUndoButton(spec, std::move(action));
      }
      break;
    case OpenToastKind::kProfileSwitched:
      set(with_detail(u"Switched to ", u"Profile Switched"), Glyph::kCheck,
          "person.crop.circle");
      break;
    // Peek and Little Open.
    case OpenToastKind::kPeekClosed:
      set(u"Peek closed", Glyph::kNone, nullptr);
      if (action) {
        SetUndoButton(spec, std::move(action));
      }
      break;
    case OpenToastKind::kPeekPromoted:
      set(u"Opened as Tab", Glyph::kExpand,
          "arrow.up.left.and.arrow.down.right");
      break;
    case OpenToastKind::kSentToLittleOpen:
      set(u"Opened in Little Open", Glyph::kPopup, "macwindow.on.rectangle");
      break;
    // Extensions.
    case OpenToastKind::kExtensionInstalled:
      set(with_detail(u"Added ", u"Extension Added"), Glyph::kPuzzle,
          "puzzlepiece.extension");
      break;
    case OpenToastKind::kExtensionLoadFailed:
      set(u"Couldn't load extension", Glyph::kPuzzle, "puzzlepiece.extension");
      spec.subtitle = detail;
      spec.lifetime = base::Seconds(6);
      break;
    case OpenToastKind::kExtensionPinned:
      set(with_detail(u"Pinned ", u"Extension Pinned"), Glyph::kPuzzle,
          "pin.fill");
      break;
    case OpenToastKind::kExtensionUnpinned:
      set(with_detail(u"Unpinned ", u"Extension Unpinned"), Glyph::kPuzzle,
          "pin.slash");
      break;
    // Boosts and Zap.
    case OpenToastKind::kBoostApplied:
      set(u"Boost Applied", Glyph::kBoost, nullptr);
      break;
    case OpenToastKind::kBoostDisabled:
      set(u"Boost Turned Off", Glyph::kBoost, nullptr);
      break;
    case OpenToastKind::kBoostFailed:
      set(u"Could not apply Boosts.", Glyph::kBoost, nullptr);
      break;
    case OpenToastKind::kZapSaved:
      set(u"Zapped", Glyph::kBolt, "bolt.fill");
      if (action) {
        SetUndoButton(spec, std::move(action));
      }
      break;
    // Ad blocking and site data.
    case OpenToastKind::kAdBlockEnabled:
      set(u"Ad Blocking On", Glyph::kShield, "shield.fill");
      break;
    case OpenToastKind::kAdBlockPaused:
      set(with_detail(u"Ad Blocking Paused on ", u"Ad Blocking Paused"),
          Glyph::kShield, "shield.slash");
      break;
    case OpenToastKind::kAdBlockSaveFailed:
      set(u"Ad blocking settings could not be saved.", Glyph::kShield, nullptr);
      break;
    case OpenToastKind::kSiteDataClearFailed:
      set(u"Site data could not be cleared.", Glyph::kTrash, nullptr);
      spec.coalescing_key = "site-data-clear-failure";
      break;
    // Downloads.
    case OpenToastKind::kDownloadStarted:
      set(with_detail(u"Downloading ", u"Download Started"),
          Glyph::kChevronDown, "arrow.down.circle");
      SetTextButton(spec, u"Show", std::move(action));
      break;
    case OpenToastKind::kDownloadCompleted:
      set(with_detail(u"Downloaded ", u"Download Complete"), Glyph::kCheck,
          "checkmark.circle");
      SetTextButton(spec, u"Show", std::move(action));
      break;
    case OpenToastKind::kDownloadFailed:
      set(u"Download Failed", Glyph::kClose, "exclamationmark.circle");
      spec.subtitle = detail;
      break;
    // Capture.
    case OpenToastKind::kCaptureInProgress:
      set(u"Capture in Progress", Glyph::kCapture, "camera.viewfinder");
      spec.sticky = true;
      break;
    case OpenToastKind::kCaptureSaved:
      set(u"Capture Saved", Glyph::kCapture, "camera.viewfinder");
      SetTextButton(spec, u"Open", std::move(action));
      break;
    case OpenToastKind::kCaptureHint:
      spec.title = u"and drag your mouse to capture any time.";
      spec.keycaps = CaptureHintKeycaps();
      break;
    // Page.
    case OpenToastKind::kPageTranslated:
      set(with_detail(u"Translated to ", u"Page Translated"), Glyph::kGlobe,
          "globe");
      SetTextButton(spec, u"Show Original", std::move(action));
      break;
    case OpenToastKind::kZoom:
      spec.title = detail;
      spec.coalescing_key = "zoom";
      break;
    case OpenToastKind::kDeveloperModeOn:
      set(u"Developer Mode On", Glyph::kGear, "hammer.fill");
      break;
    case OpenToastKind::kDeveloperModeOff:
      set(u"Developer Mode Off", Glyph::kGear, "hammer");
      break;
    // Documents.
    case OpenToastKind::kEaselSaved:
      set(u"Easel Saved", Glyph::kCheck, nullptr);
      break;
    case OpenToastKind::kNoteSaved:
      set(u"Note Saved", Glyph::kCheck, nullptr);
      break;
    // Sync.
    case OpenToastKind::kSyncCompleted:
      set(u"Synced", Glyph::kCheck, "arrow.triangle.2.circlepath");
      break;
    case OpenToastKind::kSyncConflict:
      set(u"Sync Conflict", Glyph::kSwap,
          "exclamationmark.arrow.triangle.2.circlepath");
      spec.subtitle = detail;
      SetTextButton(spec, u"Show", std::move(action));
      break;
    case OpenToastKind::kSyncFailed:
      set(u"Sync Failed", Glyph::kNone, "exclamationmark.icloud");
      spec.subtitle = detail;
      break;
    // Generic.
    case OpenToastKind::kInfo:
      set(detail, Glyph::kNone, "info.circle");
      break;
    case OpenToastKind::kWarning:
      set(detail, Glyph::kNone, "exclamationmark.triangle.fill");
      break;
    case OpenToastKind::kError:
      set(detail, Glyph::kNone, "xmark.octagon.fill");
      break;
  }
  return spec;
}

// static
ToastSpec ToastSpec::Undo(std::u16string title, base::OnceClosure undo) {
  ToastSpec spec;
  spec.title = std::move(title);
  SetUndoButton(spec, std::move(undo));
  return spec;
}

// static
ToastSpec ToastSpec::Info(std::u16string title, std::u16string subtitle) {
  ToastSpec spec = ForKind(OpenToastKind::kInfo, std::move(title));
  spec.subtitle = std::move(subtitle);
  return spec;
}

// static
ToastSpec ToastSpec::Warning(std::u16string title, std::u16string subtitle) {
  ToastSpec spec = ForKind(OpenToastKind::kWarning, std::move(title));
  spec.subtitle = std::move(subtitle);
  return spec;
}

// static
ToastSpec ToastSpec::Error(std::u16string title, std::u16string subtitle) {
  ToastSpec spec = ForKind(OpenToastKind::kError, std::move(title));
  spec.subtitle = std::move(subtitle);
  spec.lifetime = base::Seconds(6);
  return spec;
}

// static
ToastSpec ToastSpec::CopiedUrl() {
  ToastSpec spec;
  spec.kind = OpenToastKind::kCopiedUrl;
  spec.title = u"Copied Current URL";
  spec.glyph = Glyph::kLink;
  return spec;
}

// static
ToastSpec ToastSpec::TabArchived(base::OnceClosure undo) {
  // Kept as before: a text "Undo" button (automation reads its label).
  ToastSpec spec;
  spec.kind = OpenToastKind::kTabArchived;
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
  spec.kind = OpenToastKind::kSpaceSwitched;
  spec.title = space_title;
  spec.leading_text = icon_text;
  return spec;
}

namespace toast_internal {

class ToastView : public views::View {
  METADATA_HEADER(ToastView, views::View)

 public:
  ToastView(OpenToastStackView* stack,
            int id,
            ToastSpec spec,
            const secondary::Appearance& appearance)
      : stack_(stack), id_(id), appearance_(appearance) {
    GetViewAccessibility().SetRole(ax::mojom::Role::kAlert);
    // Moving onto the button still counts as hovering the toast.
    SetNotifyEnterExitOnChild(true);
    SetPaintToLayer();
    layer()->SetFillsBoundsOpaquely(false);
    scale_motion_ = std::make_unique<motion::OpenSpringAnimator>(
        motion::kToastIn,
        base::BindRepeating(&ToastView::OnScaleStep, base::Unretained(this)),
        base::BindRepeating(&ToastView::OnScaleSettled,
                            base::Unretained(this)));
    scale_motion_->set_epsilon(0.002);
    offset_motion_ = std::make_unique<motion::OpenSpringAnimator>(
        motion::kToastIn,
        base::BindRepeating(&ToastView::OnOffsetStep, base::Unretained(this)));
    opacity_motion_ = std::make_unique<motion::OpenSpringAnimator>(
        motion::kToastIn,
        base::BindRepeating(&ToastView::OnOpacityStep, base::Unretained(this)));
    opacity_motion_->set_epsilon(0.002);
    Apply(std::move(spec));
  }

  ~ToastView() override {
    scale_motion_->SetCompositor(nullptr);
    offset_motion_->SetCompositor(nullptr);
    opacity_motion_->SetCompositor(nullptr);
  }

  int id() const { return id_; }
  OpenToastKind kind() const { return spec_.kind; }
  const std::u16string& title() const { return spec_.title; }
  bool is_exiting() const { return exiting_; }
  bool needs_entrance() const { return needs_entrance_; }
  bool has_button() const { return button_ != nullptr; }

  // Lays the toast out for `spec` (a new toast or an update of this one).
  void Apply(ToastSpec spec) {
    namespace m = toast_metrics;
    const bool was_sticky = applied_ && spec_.sticky;
    spec_ = std::move(spec);
    GetViewAccessibility().SetName(spec_.subtitle.empty()
                                       ? spec_.title
                                       : spec_.title + u", " + spec_.subtitle);
    if (button_) {
      RemoveChildViewT(button_.ExtractAsDangling());
    }
    if (spec_.has_button()) {
      const std::u16string name =
          spec_.button_label.empty() ? u"Undo" : spec_.button_label;
      button_ = AddChildView(std::make_unique<PaintedButton>(
          base::BindRepeating([](ToastView* toast) { toast->PressButton(); },
                              base::Unretained(this)),
          base::BindRepeating(&ToastView::PaintButton, base::Unretained(this)),
          name));
    }
    if (!applied_ || was_sticky != spec_.sticky) {
      lifetime_ = spec_.lifetime.value_or(
          spec_.has_button() ? m::kLifetimeWithButton : m::kLifetime);
      RestartTimer(lifetime_);
    }
    applied_ = true;
    InvalidateLayout();
    SchedulePaint();
  }

  int PreferredWidth() const {
    namespace m = toast_metrics;
    return std::clamp(NaturalWidth(), m::kMinWidth, m::kMaxWidth);
  }

  int PreferredHeight() const {
    namespace m = toast_metrics;
    if (!spec_.subtitle.empty()) {
      return m::kHeightTwoLine;
    }
    return button_ ? m::kHeightWithButton : m::kHeight;
  }

  void SetAppearance(const secondary::Appearance& appearance) {
    appearance_ = appearance;
    SchedulePaint();
    if (button_) {
      button_->SchedulePaint();
    }
  }

  // --- Motion ---------------------------------------------------------------

  void AnimateIn() {
    needs_entrance_ = false;
    if (!CanAnimate()) {
      return;
    }
    scale_motion_->SetCompositor(compositor());
    opacity_motion_->SetCompositor(compositor());
    scale_motion_->SetSpring(motion::kToastIn);
    scale_motion_->AnimateFromTo(kToastInScale, 1.0);
    opacity_motion_->AnimateTimed(
        0.0, 1.0, motion::Seconds(motion::kToastFadeIn), kLinearCurve);
  }

  // Older toasts move down when a new one arrives above them.
  void SlideFrom(int dy) {
    if (dy == 0 || exiting_ || !CanAnimate()) {
      return;
    }
    offset_motion_->SetCompositor(compositor());
    offset_motion_->AnimateFromTo(offset_ + dy, 0.0,
                                  offset_motion_->velocity());
  }

  void BeginExit() {
    if (exiting_) {
      return;
    }
    exiting_ = true;
    timer_.Stop();
    if (button_) {
      button_->SetEnabled(false);
    }
    if (!CanAnimate()) {
      stack_->ScheduleRemove(this);
      return;
    }
    scale_motion_->SetCompositor(compositor());
    opacity_motion_->SetCompositor(compositor());
    const base::TimeDelta out = motion::Seconds(motion::kToastOut);
    scale_motion_->AnimateTimed(scale_, kToastOutScale, out, kToastOutCurve);
    opacity_motion_->AnimateTimed(opacity_, 0.0, out, kLinearCurve);
    // If the compositor stops stepping (window hidden mid-exit), the toast
    // still goes. Removal is idempotent.
    timer_.Start(
        FROM_HERE, out + base::Milliseconds(100),
        base::BindOnce(
            [](ToastView* toast) { toast->stack_->ScheduleRemove(toast); },
            base::Unretained(this)));
  }

  bool PressButton() {
    if (exiting_ || !button_) {
      return false;
    }
    base::OnceClosure action = std::move(spec_.button_action);
    // Leave first: the action may show another toast or close this window.
    BeginExit();
    if (action) {
      std::move(action).Run();
    }
    return true;
  }

  // views::View:
  void Layout(PassKey) override {
    namespace m = toast_metrics;
    if (button_) {
      const int w = ButtonWidth();
      const int top = spec_.subtitle.empty()
                          ? m::kButtonTop
                          : (height() - m::kButtonHeight) / 2;
      button_->SetBoundsRect(gfx::Rect(width() - m::kButtonTrailing - w, top, w,
                                       m::kButtonHeight));
    }
    ApplyTransform();
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
    const SkColor ink = appearance_.toast_text;
    // A short text-only toast ("90%") is padded to the minimum width with
    // its content centered.
    const int slack = std::max(0, width() - NaturalWidth());
    int x = m::kLeadingPadding + slack / 2;
    const gfx::Rect symbol(x, (height() - m::kSymbolSize) / 2, m::kSymbolSize,
                           m::kSymbolSize);
    if (!spec_.leading_text.empty()) {
      secondary::DrawText(canvas, spec_.leading_text, secondary::FontOfSize(13),
                          ink, symbol, gfx::Canvas::TEXT_ALIGN_CENTER);
      x += m::kSymbolSize + m::kSymbolToTitle;
    } else if (HasSymbol()) {
      const bool drew =
          !spec_.symbol_name.empty() &&
          glyphs::DrawSystemSymbol(canvas, spec_.symbol_name, m::kSymbolSize,
                                   glyphs::SymbolWeight::kMedium,
                                   gfx::RectF(symbol), ink);
      if (!drew && spec_.glyph != Glyph::kNone) {
        secondary::PaintGlyph(canvas, spec_.glyph, gfx::RectF(symbol), ink);
      }
      x += m::kSymbolSize + m::kSymbolToTitle;
    }
    // Keycap plates ("⌘", "⇧") before the title.
    const gfx::FontList title_font = TitleFont();
    for (size_t i = 0; i < spec_.keycaps.size(); ++i) {
      const int w = KeycapWidth(spec_.keycaps[i]);
      const gfx::Rect cap(x, (height() - m::kKeycapHeight) / 2, w,
                          m::kKeycapHeight);
      secondary::FillRoundRect(canvas, gfx::RectF(cap), m::kKeycapRadius,
                               secondary::WithAlpha(ink, m::kKeycapAlpha));
      secondary::DrawText(canvas, spec_.keycaps[i], title_font, ink, cap,
                          gfx::Canvas::TEXT_ALIGN_CENTER);
      x += w +
           (i + 1 == spec_.keycaps.size() ? m::kKeycapToTitle : m::kKeycapGap);
    }
    const int right = button_ ? button_->x() - m::kLabelToButton
                              : width() - m::kTrailingPadding;
    const int text_w = std::max(0, right - x);
    if (spec_.subtitle.empty()) {
      secondary::DrawText(canvas, spec_.title, title_font, ink,
                          gfx::Rect(x, 0, text_w, height()));
      return;
    }
    const gfx::FontList sub_font = SubtitleFont();
    const int title_h = title_font.GetHeight();
    const int sub_h = sub_font.GetHeight();
    const int top = (height() - title_h - m::kLineGap - sub_h) / 2;
    secondary::DrawText(canvas, spec_.title, title_font, ink,
                        gfx::Rect(x, top, text_w, title_h));
    secondary::DrawText(
        canvas, spec_.subtitle, sub_font, secondary::WithAlpha(ink, 0.72f),
        gfx::Rect(x, top + title_h + m::kLineGap, text_w, sub_h));
  }

  void OnMouseEntered(const ui::MouseEvent& event) override {
    hovered_ = true;
    if (!exiting_) {
      timer_.Stop();  // Hover holds the toast (not one already leaving).
    }
  }

  void OnMouseExited(const ui::MouseEvent& event) override {
    hovered_ = false;
    // The pointer leaving restarts the timer with 1.5 s left.
    RestartTimer(toast_metrics::kHoverResume);
  }

 private:
  bool HasSymbol() const {
    return spec_.glyph != Glyph::kNone || !spec_.symbol_name.empty();
  }

  gfx::FontList TitleFont() const {
    return secondary::FontOfSize(toast_metrics::kFontSize,
                                 gfx::Font::Weight::MEDIUM);
  }

  gfx::FontList SubtitleFont() const {
    return secondary::FontOfSize(toast_metrics::kSubtitleFontSize);
  }

  int KeycapWidth(const std::u16string& key) const {
    // Ink + 18 (the advance is a little wider than the ink).
    return std::max(toast_metrics::kKeycapHeight,
                    secondary::TextWidth(key, TitleFont()) +
                        toast_metrics::kKeycapInkPadding - 4);
  }

  int NaturalWidth() const {
    namespace m = toast_metrics;
    int width = m::kLeadingPadding;
    if (!spec_.leading_text.empty() || HasSymbol()) {
      width += m::kSymbolSize + m::kSymbolToTitle;
    }
    for (size_t i = 0; i < spec_.keycaps.size(); ++i) {
      width +=
          KeycapWidth(spec_.keycaps[i]) +
          (i + 1 == spec_.keycaps.size() ? m::kKeycapToTitle : m::kKeycapGap);
    }
    width +=
        std::max(secondary::TextWidth(spec_.title, TitleFont()),
                 spec_.subtitle.empty()
                     ? 0
                     : secondary::TextWidth(spec_.subtitle, SubtitleFont()));
    width += spec_.has_button()
                 ? m::kLabelToButton + ButtonWidth() + m::kButtonTrailing
                 : m::kTrailingPadding;
    return width;
  }

  int ButtonWidth() const {
    if (spec_.has_icon_button()) {
      return toast_metrics::kIconButtonWidth;
    }
    return std::max(32, secondary::TextWidth(spec_.button_label,
                                             secondary::FontOfSize(13)) +
                            16);
  }

  void PaintButton(gfx::Canvas* canvas, const gfx::Rect& bounds, bool hovered) {
    secondary::FillRoundRect(
        canvas, gfx::RectF(bounds), toast_metrics::kButtonRadius,
        secondary::WithAlpha(SK_ColorWHITE, hovered ? 0.32f : 0.22f));
    if (spec_.has_icon_button()) {
      const float s = toast_metrics::kButtonSymbolSize;
      const gfx::RectF box(bounds.CenterPoint().x() - s / 2.f,
                           bounds.CenterPoint().y() - s / 2.f, s, s);
      const bool drew =
          !spec_.button_symbol_name.empty() &&
          glyphs::DrawSystemSymbol(canvas, spec_.button_symbol_name, s,
                                   glyphs::SymbolWeight::kMedium, box,
                                   appearance_.toast_text);
      if (!drew) {
        secondary::PaintGlyph(canvas, spec_.button_glyph, box,
                              appearance_.toast_text);
      }
      return;
    }
    secondary::DrawText(canvas, spec_.button_label,
                        secondary::FontOfSize(13, gfx::Font::Weight::MEDIUM),
                        appearance_.toast_text, bounds,
                        gfx::Canvas::TEXT_ALIGN_CENTER);
  }

  void RestartTimer(base::TimeDelta delay) {
    if (exiting_) {
      return;  // timer_ holds the exit's removal fallback.
    }
    timer_.Stop();
    if (spec_.sticky || hovered_) {
      return;
    }
    timer_.Start(FROM_HERE, delay,
                 base::BindOnce(&ToastView::BeginExit, base::Unretained(this)));
  }

  ui::Compositor* compositor() {
    views::Widget* widget = GetWidget();
    return widget ? widget->GetCompositor() : nullptr;
  }

  bool CanAnimate() {
    return compositor() && !motion::PrefersReducedMotion() && GetWidget() &&
           GetWidget()->IsVisible();
  }

  void ApplyTransform() {
    gfx::Transform transform;
    transform.Translate(0, static_cast<float>(offset_));
    if (scale_ != 1.0) {
      // Grow from / shrink toward the top center.
      const float cx = width() / 2.f;
      transform.Translate(cx, 0);
      transform.Scale(static_cast<float>(scale_), static_cast<float>(scale_));
      transform.Translate(-cx, 0);
    }
    layer()->SetTransform(transform);
  }

  void OnScaleStep(double value) {
    scale_ = value;
    ApplyTransform();
  }

  void OnScaleSettled() {
    if (exiting_) {
      stack_->ScheduleRemove(this);
    }
  }

  void OnOffsetStep(double value) {
    offset_ = value;
    ApplyTransform();
  }

  void OnOpacityStep(double value) {
    opacity_ = std::clamp(value, 0.0, 1.0);
    layer()->SetOpacity(static_cast<float>(opacity_));
  }

  raw_ptr<OpenToastStackView> stack_;
  const int id_;
  ToastSpec spec_;
  secondary::Appearance appearance_;
  raw_ptr<PaintedButton> button_ = nullptr;
  base::TimeDelta lifetime_;
  base::OneShotTimer timer_;
  bool applied_ = false;
  bool exiting_ = false;
  bool hovered_ = false;
  bool needs_entrance_ = true;
  double scale_ = 1.0;
  double offset_ = 0.0;
  double opacity_ = 1.0;
  std::unique_ptr<motion::OpenSpringAnimator> scale_motion_;
  std::unique_ptr<motion::OpenSpringAnimator> offset_motion_;
  std::unique_ptr<motion::OpenSpringAnimator> opacity_motion_;
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

int OpenToastStackView::Show(ToastSpec spec) {
  const bool was_empty = toasts_.empty();
  last_title_ = spec.title;
  last_kind_ = spec.kind;
  if (replaces_older_) {
    // Arc (PG-1.8): every older toast starts its exit at once.
    for (auto& older : toasts_) {
      older->BeginExit();
    }
  }
  const int id = next_toast_id_++;
  auto* toast = AddChildViewAt(std::make_unique<toast_internal::ToastView>(
                                   this, id, std::move(spec), appearance_),
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
  return id;
}

int OpenToastStackView::ShowKind(OpenToastKind kind,
                                 std::u16string detail,
                                 base::OnceClosure action) {
  return Show(ToastSpec::ForKind(kind, std::move(detail), std::move(action)));
}

int OpenToastStackView::ShowCopiedUrl() {
  return Show(ToastSpec::CopiedUrl());
}

int OpenToastStackView::ShowUndo(std::u16string title, base::OnceClosure undo) {
  return Show(ToastSpec::Undo(std::move(title), std::move(undo)));
}

int OpenToastStackView::ShowTabArchived(base::OnceClosure undo) {
  return Show(ToastSpec::TabArchived(std::move(undo)));
}

int OpenToastStackView::ShowSpaceSwitched(const std::u16string& space_title,
                                          const std::u16string& icon_text) {
  return Show(ToastSpec::SpaceSwitched(space_title, icon_text));
}

toast_internal::ToastView* OpenToastStackView::FindToast(int toast_id) const {
  for (const auto& toast : toasts_) {
    if (toast->id() == toast_id) {
      return toast.get();
    }
  }
  return nullptr;
}

bool OpenToastStackView::IsShowing(int toast_id) const {
  toast_internal::ToastView* toast = FindToast(toast_id);
  return toast && !toast->is_exiting();
}

void OpenToastStackView::Update(int toast_id, ToastSpec spec) {
  toast_internal::ToastView* toast = FindToast(toast_id);
  if (!toast || toast->is_exiting()) {
    return;
  }
  last_title_ = spec.title;
  last_kind_ = spec.kind;
  toast->Apply(std::move(spec));
  PreferredSizeChanged();
  InvalidateLayout();
}

void OpenToastStackView::Dismiss(int toast_id) {
  if (toast_internal::ToastView* toast = FindToast(toast_id)) {
    toast->BeginExit();
  }
}

void OpenToastStackView::DismissKind(OpenToastKind kind) {
  for (auto& toast : toasts_) {
    if (toast->kind() == kind) {
      toast->BeginExit();
    }
  }
}

bool OpenToastStackView::PerformAction(size_t index) {
  size_t visible = 0;
  for (auto& toast : toasts_) {
    if (toast->is_exiting()) {
      continue;
    }
    if (visible++ == index) {
      return toast->PressButton();
    }
  }
  return false;
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
  const int id = toast->id();
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<OpenToastStackView> stack, int id) {
                       if (stack) {
                         if (auto* target = stack->FindToast(id)) {
                           stack->Remove(target);
                         }
                       }
                     },
                     weak_factory_.GetWeakPtr(), id));
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
    const gfx::Rect old_bounds = toast->bounds();
    // Right-aligned: the stack's right edge is the panel's trailing inset.
    const gfx::Rect bounds(inner.right() - w, y, w, h);
    toast->SetBoundsRect(bounds);
    if (toast->needs_entrance()) {
      toast->AnimateIn();
    } else if (!old_bounds.IsEmpty()) {
      // Slide from where it was (the widget's top-right anchor keeps x).
      toast->SlideFrom(old_bounds.y() - bounds.y());
    }
    y += h + toast_metrics::kStackGap;
  }
}

BEGIN_METADATA(OpenToastStackView)
END_METADATA

// ===========================================================================
// OpenTabSwitcherView.
// ===========================================================================

TabSwitcherItem::TabSwitcherItem() = default;
TabSwitcherItem::TabSwitcherItem(const TabSwitcherItem&) = default;
TabSwitcherItem::TabSwitcherItem(TabSwitcherItem&&) noexcept = default;
TabSwitcherItem& TabSwitcherItem::operator=(const TabSwitcherItem&) = default;
TabSwitcherItem& TabSwitcherItem::operator=(TabSwitcherItem&&) noexcept =
    default;
TabSwitcherItem::~TabSwitcherItem() = default;

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
  thumbnails_requested_.clear();
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
  base::WeakPtr<OpenTabSwitcherView> weak = weak_factory_.GetWeakPtr();
  if (delegate_) {
    delegate_->OnTabSwitcherVisibilityChanged(true);
  }
  if (!weak || !active_) {
    return;
  }
  RequestFocus();
  SchedulePaint();
  // Only once the HUD shows: a quick Ctrl+Tab tap captures nothing.
  RequestVisibleThumbnails();
}

void OpenTabSwitcherView::RequestVisibleThumbnails() {
  if (!delegate_ || !shown_) {
    return;
  }
  std::vector<ItemID> wanted;
  const size_t first = first_visible();
  const size_t count =
      std::min(items_.size() - first, tab_switcher_metrics::kMaximumVisible);
  for (size_t i = first; i < first + count; ++i) {
    const TabSwitcherItem& item = items_[i];
    if (!item.thumbnail.isNull() || item.is_sleeping ||
        std::find(thumbnails_requested_.begin(), thumbnails_requested_.end(),
                  item.tab_id) != thumbnails_requested_.end()) {
      continue;
    }
    thumbnails_requested_.push_back(item.tab_id);
    wanted.push_back(item.tab_id);
  }
  if (!wanted.empty()) {
    delegate_->OnTabSwitcherNeedsThumbnails(wanted);
  }
}

void OpenTabSwitcherView::UpdateThumbnail(const ItemID& tab_id,
                                          const gfx::ImageSkia& thumbnail) {
  if (!active_ || thumbnail.isNull()) {
    return;
  }
  for (TabSwitcherItem& item : items_) {
    if (item.tab_id == tab_id) {
      item.thumbnail = thumbnail;
      if (shown_) {
        SchedulePaint();
      }
      return;
    }
  }
}

void OpenTabSwitcherView::UpdateFavicon(const ItemID& tab_id,
                                        const gfx::ImageSkia& favicon) {
  if (!active_ || favicon.isNull()) {
    return;
  }
  for (TabSwitcherItem& item : items_) {
    if (item.tab_id == tab_id) {
      item.favicon = favicon;
      if (shown_) {
        SchedulePaint();
      }
      return;
    }
  }
}

// static
gfx::Size OpenTabSwitcherView::ThumbnailSize() {
  namespace m = tab_switcher_metrics;
  const int width = m::kItemWidth - 2 * m::kThumbnailInset;
  return gfx::Size(
      width, width * m::kThumbnailAspectHeight / m::kThumbnailAspectWidth);
}

std::vector<ItemID> OpenTabSwitcherView::visible_tab_ids() const {
  std::vector<ItemID> ids;
  if (!active_) {
    return ids;
  }
  const size_t first = first_visible();
  const size_t count =
      std::min(items_.size() - first, tab_switcher_metrics::kMaximumVisible);
  for (size_t i = first; i < first + count; ++i) {
    ids.push_back(items_[i].tab_id);
  }
  return ids;
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
  base::WeakPtr<OpenTabSwitcherView> weak = weak_factory_.GetWeakPtr();
  if (delegate_) {
    delegate_->OnTabSwitcherHighlight(items_[highlight_].tab_id);
  }
  if (!weak || !active_) {
    return;
  }
  SchedulePaint();
  // The window may have scrolled to cards without a snapshot yet.
  RequestVisibleThumbnails();
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
  // Cards with their labels; no heading (each card names its tab).
  return gfx::Rect(
      inner.x() + m::kInset +
          static_cast<int>(visible_index) * (m::kItemWidth + m::kGap),
      inner.y() + m::kInset, m::kItemWidth, m::kItemHeight);
}

gfx::Size OpenTabSwitcherView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  namespace m = tab_switcher_metrics;
  const int n = static_cast<int>(
      std::max<size_t>(1, std::min(items_.size(), m::kMaximumVisible)));
  return gfx::Size(2 * m::kInset + n * m::kItemWidth + (n - 1) * m::kGap +
                       GetInsets().width(),
                   2 * m::kInset + m::kItemHeight + GetInsets().height());
}

void OpenTabSwitcherView::OnPaint(gfx::Canvas* canvas) {
  namespace m = tab_switcher_metrics;
  if (!shown_ || items_.empty()) {
    return;
  }
  const bool dark = appearance_.dark;
  const gfx::Rect inner = inner_bounds();
  secondary::FillRoundRectWithShadow(
      canvas, gfx::RectF(inner), m::kCornerRadius,
      dark ? kPopoverDark : kPopoverLight,
      dark ? kPopoverShadowDark : kPopoverShadowLight, 8.f, 30.f);
  const size_t first = first_visible();
  const size_t count = std::min(items_.size() - first, m::kMaximumVisible);
  for (size_t i = 0; i < count; ++i) {
    PaintCard(canvas, items_[first + i], ItemRect(i), first + i == highlight_);
  }
}

void OpenTabSwitcherView::PaintCard(gfx::Canvas* canvas,
                                    const TabSwitcherItem& item,
                                    const gfx::Rect& item_rect,
                                    bool selected) {
  namespace m = tab_switcher_metrics;
  const bool dark = appearance_.dark;
  const SkColor text = dark ? kInputTextDark : kInputTextLight;
  const SkColor tone = dark ? SK_ColorWHITE : SK_ColorBLACK;
  const gfx::Rect card(item_rect.x(), item_rect.y(), item_rect.width(),
                       m::kCardHeight);
  secondary::FillRoundRect(
      canvas, gfx::RectF(card), m::kCardRadius,
      secondary::WithAlpha(tone, selected ? 0.10f : 0.05f));

  // Thumbnail frame: the card inset by 6, radius 6.
  gfx::Rect frame = card;
  frame.Inset(m::kThumbnailInset);
  const SkRRect clip = SkRRect::MakeRectXY(
      gfx::RectToSkRect(frame), m::kThumbnailRadius, m::kThumbnailRadius);
  if (!item.thumbnail.isNull() && item.thumbnail.width() > 0 &&
      item.thumbnail.height() > 0) {
    // Aspect-fill, top aligned: the page's top edge and full width matter
    // most; a 16:10 capture loses a few points at each side.
    const float scale =
        std::max(frame.width() / static_cast<float>(item.thumbnail.width()),
                 frame.height() / static_cast<float>(item.thumbnail.height()));
    const int w = static_cast<int>(item.thumbnail.width() * scale + 0.5f);
    const int h = static_cast<int>(item.thumbnail.height() * scale + 0.5f);
    canvas->Save();
    canvas->sk_canvas()->clipRRect(clip, true);
    secondary::DrawImageInRect(
        canvas, item.thumbnail,
        gfx::Rect(frame.CenterPoint().x() - w / 2, frame.y(), w, h));
    canvas->Restore();
    // A hairline keeps a white page apart from a light card.
    secondary::StrokeRoundRect(canvas, gfx::RectF(frame), m::kThumbnailRadius,
                               secondary::WithAlpha(tone, 0.08f), 1.f);
  } else {
    // Placeholder: the page is still being captured, or the tab sleeps.
    secondary::FillRoundRect(canvas, gfx::RectF(frame), m::kThumbnailRadius,
                             secondary::WithAlpha(tone, 0.05f));
    const int icon = 32;
    const int caption_h = item.is_sleeping ? 18 : 0;
    const gfx::Rect icon_rect(frame.CenterPoint().x() - icon / 2,
                              frame.CenterPoint().y() - (icon + caption_h) / 2,
                              icon, icon);
    if (item.favicon.isNull()) {
      secondary::PaintGlyph(canvas, Glyph::kGlobe, gfx::RectF(icon_rect),
                            secondary::WithAlpha(text, 0.45f));
    } else {
      if (item.is_sleeping) {
        canvas->SaveLayerAlpha(150);
      }
      secondary::DrawImageInRect(canvas, item.favicon, icon_rect);
      if (item.is_sleeping) {
        canvas->Restore();
      }
    }
    if (item.is_sleeping) {
      secondary::DrawText(
          canvas, u"Sleeping", secondary::FontOfSize(11),
          secondary::WithAlpha(text, 0.55f),
          gfx::Rect(frame.x(), icon_rect.bottom() + 4, frame.width(), 14),
          gfx::Canvas::TEXT_ALIGN_CENTER);
    }
  }
  if (selected) {
    // Active accent ring around the card.
    gfx::RectF ring(card);
    ring.Inset(-1.5f);
    secondary::StrokeRoundRect(canvas, ring, m::kCardRadius + 1.5f,
                               appearance_.ActiveAccent(), 2.5f);
  }

  // Label: favicon 16 + title, then "host · Space".
  const int label_top = card.bottom() + 6;
  int text_x = card.x() + 2;
  const int line1_h = 17;
  if (!item.favicon.isNull()) {
    secondary::DrawImageInRect(
        canvas, item.favicon,
        gfx::Rect(text_x, label_top + (line1_h - 16) / 2, 16, 16));
    text_x += 21;
  }
  secondary::DrawText(
      canvas, item.title.empty() ? item.host : item.title,
      secondary::FontOfSize(12, selected ? gfx::Font::Weight::SEMIBOLD
                                         : gfx::Font::Weight::MEDIUM),
      text, gfx::Rect(text_x, label_top, card.right() - text_x, line1_h));
  const std::u16string& subtitle =
      item.subtitle.empty() ? item.host : item.subtitle;
  if (!subtitle.empty()) {
    secondary::DrawText(
        canvas, subtitle, secondary::FontOfSize(11),
        secondary::WithAlpha(text, 0.55f),
        gfx::Rect(card.x() + 2, label_top + line1_h, card.width() - 2, 14));
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
