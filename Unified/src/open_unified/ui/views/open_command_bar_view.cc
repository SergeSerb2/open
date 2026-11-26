// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_command_bar_view.h"

#include <algorithm>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/string_util.h"
#include "build/build_config.h"
#include "cc/paint/paint_flags.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/events/event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/range/range.h"
#include "ui/gfx/shadow_value.h"
#include "ui/gfx/skia_paint_util.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/border.h"
#include "ui/views/controls/textfield/textfield.h"

namespace open_unified {

namespace {

using secondary::Glyph;
namespace m = command_bar_metrics;

// Light/Dark card colors (CommandCard, D3 §2.1).
constexpr SkColor kBodyLight = SkColorSetRGB(0xF9, 0xF9, 0xF9);
constexpr SkColor kBodyDark = SkColorSetRGB(0x30, 0x30, 0x2E);
constexpr SkColor kTextLight = SkColorSetRGB(0x1E, 0x1E, 0x1C);
constexpr SkColor kTextDark = SkColorSetRGB(0xF4, 0xF3, 0xEE);
constexpr float kSecondaryAlpha = 0.56f;
// Shadow y 22, blur 70 (σ 35), black 38 %, plus a 0.5 pt black 22 % hairline.
constexpr float kShadowOffsetY = 22.f;
constexpr float kShadowBlur = 70.f;
constexpr float kShadowAlpha = 0.38f;
constexpr float kHairlineWidth = 0.5f;
// Scrim behind the New Tab card only.
constexpr float kScrimAlpha = 0.10f;
// Rows (D3): radius 8, white 24 pt tile radius 6 with a 16 pt favicon,
// selected subtitle white 0.8, trailing hint 13 pt semibold, 20 pt key cap
// radius 5, 8 pt gap. Title max 475 pt (commandbar.md §3.2).
constexpr int kRowRadius = 8;
constexpr int kTileSize = 24;
constexpr int kTileRadius = 6;
constexpr int kTileFavicon = 16;
constexpr int kRowIconSize = 18;
constexpr int kTitleMaxWidth = 475;
constexpr int kSubtitleGap = 4;
constexpr int kHintFontSize = 13;
constexpr int kKeyCapSize = 20;
constexpr int kKeyCapRadius = 5;
constexpr int kHintGap = 8;
// Input hint group: keycaps 24 tall, radius 5, 4 pt label padding, right
// edge at W − 22, "Search Google" to keycap 10, keycap to "or" 8.
constexpr int kInputKeycapHeight = 24;
constexpr int kInputKeycapPadding = 4;
constexpr int kHintTrailing = 22;
constexpr int kHintLabelGap = 10;
constexpr int kHintKeyGap = 8;

bool StartsWithIgnoringAsciiCase(std::u16string_view text,
                                 std::u16string_view prefix) {
  if (prefix.size() > text.size()) {
    return false;
  }
  for (size_t i = 0; i < prefix.size(); ++i) {
    if (base::ToLowerASCII(text[i]) != base::ToLowerASCII(prefix[i])) {
      return false;
    }
  }
  return true;
}

bool HasWhitespace(std::u16string_view text) {
  return std::any_of(text.begin(), text.end(), [](char16_t c) {
    return c == u' ' || c == u'\t' || c == u'\n' || c == u'\r';
  });
}

bool IsPageLike(CommandBarRowKind kind) {
  switch (kind) {
    case CommandBarRowKind::kNavigate:
    case CommandBarRowKind::kHistory:
    case CommandBarRowKind::kSearch:
    case CommandBarRowKind::kSearchSuggestion:
    case CommandBarRowKind::kSiteSearch:
    case CommandBarRowKind::kCurrentPage:
      return true;
    default:
      return false;
  }
}

std::u16string ScopeTitle(CommandBarScope scope) {
  switch (scope) {
    case CommandBarScope::kActions:
      return u"Actions";
    case CommandBarScope::kTabs:
      return u"Tabs";
    default:
      return std::u16string();
  }
}

// CommandCardLayout `.newTab` and `.inline` (CommandBarTokens.swift).
struct CardLayout {
  int input_height;
  int icon_x;
  int icon_size;
  int icon_gap;
  int input_font;
  int padding_right;
  int list_padding_top;
  int list_padding_x;
  int list_padding_bottom;
  int row_height;
  int row_pitch;
  int row_padding_left;
  int row_padding_right;
  int row_gap;
  int row_font;

  int text_x() const { return icon_x + icon_size + icon_gap; }
  int list_top() const { return input_height + list_padding_top; }
  int title_x() const { return row_padding_left + kRowIconSize + row_gap; }
  int PanelHeight(size_t rows) const {
    if (rows == 0) {
      return input_height;
    }
    return list_top() +
           static_cast<int>(std::min<size_t>(rows, m::kMaxVisibleRows)) *
               row_pitch +
           list_padding_bottom;
  }
};

// .big: input 64 (22 / 18 padding, gap 16, 19 pt), rows 46 + 4 (13 / 9,
// gap 13, 15 pt). 64 + 5 + 50 n + 10 = 79 + 50 n (measured).
constexpr CardLayout kNewTabLayout{64, 22, 18, 16, 19, 18, 5, 9,
                                   10, 46, 50, 13, 9,  13, 15};
// .inl: input 50 (14 / 20 padding, gap 12, 15 pt, favicon 16), rows as New
// Tab with 9 / 9 padding, gap 11.
constexpr CardLayout kInlineLayout{50, 14, 16, 12, 15, 20, 5, 9,
                                   9,  46, 50, 9,  9,  11, 15};

const CardLayout& LayoutFor(bool inline_card) {
  return inline_card ? kInlineLayout : kNewTabLayout;
}

}  // namespace

OpenCommandBarView::OpenCommandBarView(CommandBarDelegate* delegate)
    : delegate_(delegate) {
  SetVisible(false);
  GetViewAccessibility().SetRole(ax::mojom::Role::kDialog);
  GetViewAccessibility().SetName(u"Command Bar");

  auto field = std::make_unique<views::Textfield>();
  field->set_controller(this);
  field->SetBorder(views::CreateEmptyBorder(gfx::Insets()));
  field->SetBackgroundEnabled(false);
  field->GetViewAccessibility().SetName(u"Search or Enter URL");
  field_ = AddChildView(std::move(field));

  auto close = std::make_unique<secondary::GlyphButton>(
      base::BindRepeating(&OpenCommandBarView::Dismiss, base::Unretained(this),
                          CommandBarDismissReason::kCloseButton),
      Glyph::kClose, u"Close");
  close->SetGlyphSize(11.f);
  close->SetPlate(secondary::GlyphButton::Plate::kCircle,
                  secondary::WithAlpha(SK_ColorBLACK, 0.05f), 13.f);
  close->SetVisible(false);
  close_button_ = AddChildView(std::move(close));
}

OpenCommandBarView::~OpenCommandBarView() {
  field_->set_controller(nullptr);
}

// static
gfx::Rect OpenCommandBarView::ComputeCardBounds(
    const gfx::Size& size,
    CommandBarMode mode,
    size_t row_count,
    const std::optional<gfx::Rect>& anchor) {
  if (mode == CommandBarMode::kLittleOpen) {
    return gfx::Rect(size);
  }
  if (anchor) {
    const int height = kInlineLayout.PanelHeight(row_count);
    const int width = std::max(m::kInlineMinimumWidth, anchor->width());
    const int x = std::max(0, std::min(anchor->x(), size.width() - width - 8));
    return gfx::Rect(x, anchor->y() + m::kInlineTopOffset, width, height);
  }
  const int width = std::min(
      m::kPanelWidth, std::max(m::kMinimumPanelWidth,
                               size.width() - 2 * m::kMinimumWindowMargin));
  const int x = (size.width() - width) / 2;
  const int y = std::max(m::kMinimumWindowMargin,
                         (size.height() - m::kCenteringHeight) / 2);
  return gfx::Rect(x, y, width, kNewTabLayout.PanelHeight(row_count));
}

void OpenCommandBarView::Present(const CommandBarRequest& request) {
  mode_ = request.mode;
  inline_anchor_ = request.mode == CommandBarMode::kEditCurrentUrl
                       ? request.inline_anchor
                       : std::nullopt;
  appearance_ = request.appearance;
  current_favicon_ = request.current_favicon;
  presented_ = true;
  scope_ = CommandBarScope::kNone;
  scope_from_command_ = false;
  site_search_id_.clear();
  scope_title_.clear();
  text_before_scope_.clear();
  results_ = {};
  selected_ = 0;
  scroll_ = 0;
  user_moved_selection_ = false;
  last_mouse_.reset();
  completion_.clear();
  last_edit_was_insertion_ = false;
  last_key_was_paste_ = false;

  field_->SetFontList(secondary::FontOfSize(LayoutFor(is_inline()).input_font));
  field_->SetTextColorId(std::nullopt);
  close_button_->SetVisible(mode_ == CommandBarMode::kLittleOpen);

  // Any mode may open prefilled (Cmd/Ctrl+L's URL, Little Open's Edit URL,
  // automation `command-bar open text=...`); the text is fully selected so
  // typing replaces it.
  const std::u16string initial_text = request.initial_text.substr(
      0, std::min(request.initial_text.size(), m::kMaxInputLength));
  typed_ = initial_text;
  field_->SetText(typed_);
  field_->ClearEditHistory();
  field_->SelectAll(false);
  pre_edit_text_ = typed_;
  pre_edit_selection_ = gfx::Range(0, typed_.size());

  if (request.mode == CommandBarMode::kSearchActions ||
      request.mode == CommandBarMode::kSearchTabs) {
    const CommandBarScope scope = request.mode == CommandBarMode::kSearchActions
                                      ? CommandBarScope::kActions
                                      : CommandBarScope::kTabs;
    scope_from_command_ = true;
    EnterScopeInternal({scope, std::string(), ScopeTitle(scope), false},
                       std::u16string());
    if (!initial_text.empty()) {
      // Entering the scope clears the field; the prefill is the scope query.
      typed_ = initial_text;
      SetFieldText(typed_, 0, typed_.size());
      field_->ClearEditHistory();
      pre_edit_text_ = typed_;
      pre_edit_selection_ = gfx::Range(0, typed_.size());
      RunQuery();
    }
  } else {
    UpdatePlaceholder();
    RunQuery();
  }

  // One frame: no animation on present (commandbar.md §5).
  SetVisible(true);
  InvalidateLayout();
  SchedulePaint();
  field_->RequestFocus();
}

void OpenCommandBarView::Dismiss(CommandBarDismissReason reason) {
  DismissInternal(reason, std::nullopt);
}

void OpenCommandBarView::DismissInternal(
    CommandBarDismissReason reason,
    std::optional<gfx::Point> click_location) {
  if (!presented_) {
    return;
  }
  presented_ = false;
  SetVisible(false);
  field_->SetText(std::u16string());
  field_->ClearEditHistory();
  typed_.clear();
  completion_.clear();
  scope_ = CommandBarScope::kNone;
  results_ = {};
  if (delegate_) {
    delegate_->OnCommandBarDismissed(reason, click_location);
  }
}

void OpenCommandBarView::UpdateResults(uint64_t generation,
                                       CommandBarResults results) {
  if (!presented_ || generation != generation_) {
    return;
  }
  ApplyResults(std::move(results));
}

void OpenCommandBarView::EnterScope(const CommandBarScopeTarget& target) {
  if (!presented_) {
    return;
  }
  EnterScopeInternal(target, typed_);
}

void OpenCommandBarView::SetAppearance(
    const secondary::Appearance& appearance) {
  appearance_ = appearance;
  SchedulePaint();
}

std::u16string_view OpenCommandBarView::field_text() const {
  return field_->GetText();
}

void OpenCommandBarView::InsertText(const std::u16string& text) {
  if (!presented_ || !field_) {
    return;
  }
  field_->RequestFocus();
  field_->InsertOrReplaceText(text);
  ContentsChanged(field_, std::u16string(field_->GetText()));
}

// --- Query and completion --------------------------------------------------

void OpenCommandBarView::RunQuery() {
  if (!delegate_) {
    return;
  }
  const bool completion_mode = mode_ == CommandBarMode::kNewTab ||
                               mode_ == CommandBarMode::kEditCurrentUrl ||
                               mode_ == CommandBarMode::kLittleOpen;
  allows_inline_ = completion_mode && scope_ == CommandBarScope::kNone &&
                   last_edit_was_insertion_ && !typed_.empty() &&
                   !HasWhitespace(typed_);
  CommandBarQuery query;
  query.text = typed_;
  query.mode = mode_;
  query.scope = scope_;
  query.site_search_id = site_search_id_;
  query.allows_inline_completion = allows_inline_;
  query.generation = ++generation_;
  ApplyResults(delegate_->QuerySuggestions(query));
}

void OpenCommandBarView::ApplyResults(CommandBarResults results) {
  std::string keep_id;
  if (user_moved_selection_ && selected_ < results_.rows.size()) {
    keep_id = results_.rows[selected_].id;
  }
  results_ = std::move(results);
  if (results_.rows.size() > m::kMaxRows) {
    results_.rows.resize(m::kMaxRows);
  }
  // Before the user moves, the selection stays on row 1; after a move it
  // follows the same suggestion id (commandbar.md §4 "Later snapshots").
  selected_ = 0;
  if (!keep_id.empty()) {
    for (size_t i = 0; i < results_.rows.size(); ++i) {
      if (results_.rows[i].id == keep_id) {
        selected_ = i;
        break;
      }
    }
  }
  scroll_ = std::min(scroll_, results_.rows.size() > m::kMaxVisibleRows
                                  ? results_.rows.size() - m::kMaxVisibleRows
                                  : size_t{0});
  EnsureSelectedVisible();
  UpdateCompletion();
  const int old_hint = HintWidth();
  UpdateCard();
  if (old_hint != HintWidth()) {
    InvalidateLayout();
  }
  SchedulePaint();
}

void OpenCommandBarView::UpdateCompletion() {
  const std::u16string& candidate = results_.inline_completion;
  const bool show = allows_inline_ && selected_ == 0 &&
                    candidate.size() > typed_.size() &&
                    StartsWithIgnoringAsciiCase(candidate, typed_);
  if (!show) {
    if (!completion_.empty()) {
      completion_.clear();
      SetFieldText(typed_, typed_.size(), typed_.size());
    }
    return;
  }
  std::u16string next = candidate.substr(typed_.size());
  if (next == completion_ && field_->GetText() == typed_ + completion_) {
    return;
  }
  completion_ = std::move(next);
  // Real text with the completed part selected (CC-2, CC-3). Writes never
  // enter undo and post no text change.
  SetFieldText(typed_ + completion_, typed_.size(),
               typed_.size() + completion_.size());
}

void OpenCommandBarView::AcceptCompletion() {
  typed_ += completion_;
  completion_.clear();
  SetFieldText(typed_, typed_.size(), typed_.size());
  last_edit_was_insertion_ = false;
  RunQuery();
}

void OpenCommandBarView::SetFieldText(const std::u16string& text,
                                      size_t sel_start,
                                      size_t sel_end) {
  if (field_->GetText() != text) {
    field_->SetText(text);
  }
  field_->SetSelectedRange(gfx::Range(sel_start, sel_end));
}

void OpenCommandBarView::ContentsChanged(views::Textfield* sender,
                                         const std::u16string& new_contents) {
  if (!presented_) {
    return;
  }
  // Marked IME text does not query; composition end submits one query.
  if (field_->HasCompositionText()) {
    return;
  }
  std::u16string text = new_contents;
  bool rewrote = false;
  // Paste replaces CR/LF with spaces and caps input at 2,048 characters.
  for (char16_t& c : text) {
    if (c == u'\n' || c == u'\r') {
      c = u' ';
      rewrote = true;
    }
  }
  if (text.size() > m::kMaxInputLength) {
    text.resize(m::kMaxInputLength);
    rewrote = true;
  }
  if (rewrote) {
    const size_t caret =
        std::min(field_->GetSelectedRange().end(), text.size());
    SetFieldText(text, caret, caret);
  }

  const gfx::Range sel = field_->GetSelectedRange();
  const bool caret_at_end = sel.is_empty() && sel.end() == text.size();
  // An insertion at the end: typing (or an IME commit) that kept everything
  // before the old selection and replaced only a trailing selection or
  // nothing. Never a paste, deletion or undo (§4.1 "When").
  const size_t keep =
      std::min(pre_edit_selection_.GetMin(), pre_edit_text_.size());
  const bool replaced_tail =
      pre_edit_selection_.GetMax() >= pre_edit_text_.size();
  const bool insertion = !last_key_was_paste_ && caret_at_end &&
                         replaced_tail && text.size() > keep &&
                         text.compare(0, keep, pre_edit_text_, 0, keep) == 0;
  last_key_was_paste_ = false;
  pre_edit_text_ = text;
  pre_edit_selection_ = sel;

  // A character that continues the completion keeps it on screen before the
  // next snapshot: only its first character is consumed (§4.1 "Keys").
  if (insertion && !completion_.empty() && text.size() == typed_.size() + 1 &&
      base::ToLowerASCII(text.back()) ==
          base::ToLowerASCII(completion_.front())) {
    completion_.erase(0, 1);
    typed_ = text;
    if (!completion_.empty()) {
      SetFieldText(typed_ + completion_, typed_.size(),
                   typed_.size() + completion_.size());
    }
  } else {
    typed_ = text;
    completion_.clear();
  }
  last_edit_was_insertion_ = insertion;
  user_moved_selection_ = false;
  RunQuery();
}

bool OpenCommandBarView::HandleKeyEvent(views::Textfield* sender,
                                        const ui::KeyEvent& event) {
  if (!presented_ || event.type() != ui::EventType::kKeyPressed) {
    return false;
  }
  // During IME composition the input method owns Return, Tab, Esc, Space and
  // the arrows.
  if (field_->HasCompositionText()) {
    return false;
  }
  const bool shift = event.IsShiftDown();
  const bool plain = !(event.flags() & (ui::EF_CONTROL_DOWN | ui::EF_ALT_DOWN |
                                        ui::EF_COMMAND_DOWN));
  pre_edit_text_ = std::u16string(field_->GetText());
  pre_edit_selection_ = field_->GetSelectedRange();
  last_key_was_paste_ = (event.key_code() == ui::VKEY_V &&
                         secondary::HasPrimaryModifier(event.flags())) ||
                        (event.key_code() == ui::VKEY_INSERT && shift);
  switch (event.key_code()) {
    case ui::VKEY_ESCAPE:
      Dismiss(CommandBarDismissReason::kEscape);
      return true;

    case ui::VKEY_RETURN:
      Commit(selected_, event.flags());
      return true;

    case ui::VKEY_UP:
      MoveSelection(-1);
      return true;

    case ui::VKEY_DOWN:
      MoveSelection(1);
      return true;

    case ui::VKEY_TAB:
      if (shift || !plain || scope_ != CommandBarScope::kNone) {
        return false;  // Normal focus traversal.
      }
      if (std::optional<CommandBarScopeTarget> target = TabScopeTarget()) {
        EnterScopeInternal(*target, typed_);
        return true;
      }
      return false;

    case ui::VKEY_RIGHT:
    case ui::VKEY_END:
      if (!completion_.empty() && !shift) {
        AcceptCompletion();
        return true;
      }
      return false;

#if BUILDFLAG(IS_MAC)
    case ui::VKEY_E:
      // Ctrl+E accepts like End.
      if (!completion_.empty() && event.IsControlDown() && !shift) {
        AcceptCompletion();
        return true;
      }
      return false;
#endif

    case ui::VKEY_LEFT:
      if (!completion_.empty() && !shift) {
        // The text becomes typed, caret at the selection start.
        const size_t caret = typed_.size();
        typed_ += completion_;
        completion_.clear();
        SetFieldText(typed_, caret, caret);
        last_edit_was_insertion_ = false;
        return true;
      }
      return false;

    case ui::VKEY_HOME:
      if (!completion_.empty() && !shift) {
        typed_ += completion_;
        completion_.clear();
        SetFieldText(typed_, 0, 0);
        last_edit_was_insertion_ = false;
        return true;
      }
      return false;

    case ui::VKEY_BACK:
    case ui::VKEY_DELETE:
      // Deletions remove only the completion and re-query with completion
      // off (CC-40).
      if (!completion_.empty()) {
        completion_.clear();
        SetFieldText(typed_, typed_.size(), typed_.size());
        last_edit_was_insertion_ = false;
        RunQuery();
        return true;
      }
      if (event.key_code() == ui::VKEY_BACK &&
          scope_ != CommandBarScope::kNone && field_->GetText().empty()) {
        ExitScope();
        return true;
      }
      return false;

    case ui::VKEY_SPACE:
      // Space never enters Site Search while a completion shows (CC-5); it
      // replaces the completion with a space.
      if (!completion_.empty() || !plain || scope_ != CommandBarScope::kNone ||
          typed_.empty() || !delegate_) {
        return false;
      }
      if (std::optional<CommandBarScopeTarget> target =
              delegate_->ResolveSiteSearch(typed_, /*exact_keyword_only=*/true);
          target && target->scope == CommandBarScope::kSiteSearch) {
        EnterScopeInternal(*target, typed_);
        return true;
      }
      return false;

    default:
      return false;
  }
}

std::optional<CommandBarScopeTarget> OpenCommandBarView::TabScopeTarget()
    const {
  // Exact words only; a scope wins over a site with the same word (§4 Tab).
  const std::u16string word = base::ToLowerASCII(typed_);
  if (word == u"actions" || word == u"action" || word == u"commands") {
    return CommandBarScopeTarget{CommandBarScope::kActions, std::string(),
                                 ScopeTitle(CommandBarScope::kActions), true};
  }
  if (word == u"tabs" || word == u"tab") {
    return CommandBarScopeTarget{CommandBarScope::kTabs, std::string(),
                                 ScopeTitle(CommandBarScope::kTabs), true};
  }
  return results_.site_search_hint;
}

void OpenCommandBarView::EnterScopeInternal(
    const CommandBarScopeTarget& target,
    const std::u16string& restore_text) {
  scope_ = target.scope;
  site_search_id_ = target.site_search_id;
  scope_title_ = target.title.empty() ? ScopeTitle(target.scope) : target.title;
  text_before_scope_ = restore_text;
  typed_.clear();
  completion_.clear();
  last_edit_was_insertion_ = false;
  user_moved_selection_ = false;
  SetFieldText(std::u16string(), 0, 0);
  UpdatePlaceholder();
  InvalidateLayout();
  RunQuery();
}

void OpenCommandBarView::ExitScope() {
  std::u16string text;
  if (scope_from_command_) {
    // A scope opened by command gives an empty Cmd+T bar.
    mode_ = CommandBarMode::kNewTab;
    scope_from_command_ = false;
  } else {
    text = text_before_scope_;
  }
  scope_ = CommandBarScope::kNone;
  site_search_id_.clear();
  scope_title_.clear();
  typed_ = text;
  completion_.clear();
  last_edit_was_insertion_ = false;
  user_moved_selection_ = false;
  SetFieldText(typed_, typed_.size(), typed_.size());
  UpdatePlaceholder();
  InvalidateLayout();
  RunQuery();
}

void OpenCommandBarView::UpdatePlaceholder() {
  if (scope_ != CommandBarScope::kNone) {
    field_->SetPlaceholderText(u"Search…");
  } else if (mode_ == CommandBarMode::kSearchTabs) {
    field_->SetPlaceholderText(u"Search Tabs…");
  } else {
    field_->SetPlaceholderText(u"Search or Enter URL…");
  }
}

// --- Selection and commit --------------------------------------------------

void OpenCommandBarView::MoveSelection(int delta) {
  if (results_.rows.empty()) {
    return;
  }
  const int last = static_cast<int>(results_.rows.size()) - 1;
  const size_t next = static_cast<size_t>(
      std::clamp(static_cast<int>(selected_) + delta, 0, last));
  if (next == selected_) {
    return;  // Stops at the ends.
  }
  selected_ = next;
  user_moved_selection_ = true;
  EnsureSelectedVisible();
  // Off row 1 hides the completion; back on row 1 shows it (no query).
  UpdateCompletion();
  SchedulePaint();
}

void OpenCommandBarView::EnsureSelectedVisible() {
  if (selected_ < scroll_) {
    scroll_ = selected_;
  } else if (selected_ >= scroll_ + m::kMaxVisibleRows) {
    scroll_ = selected_ + 1 - m::kMaxVisibleRows;
  }
}

void OpenCommandBarView::Commit(size_t index, int event_flags) {
  // An empty snapshot consumes Return without opening anything.
  if (!delegate_ || index >= results_.rows.size()) {
    return;
  }
  const CommandBarRow& row = results_.rows[index];
  CommandBarDisposition disposition =
      mode_ == CommandBarMode::kEditCurrentUrl ||
              mode_ == CommandBarMode::kLittleOpen
          ? CommandBarDisposition::kCurrentTab
          : CommandBarDisposition::kNewForegroundTab;
  if (IsPageLike(row.kind)) {
    if (secondary::HasPrimaryModifier(event_flags)) {
      disposition = CommandBarDisposition::kNewBackgroundTab;
    } else if (event_flags & ui::EF_ALT_DOWN) {
      disposition = CommandBarDisposition::kSplitView;
    }
  }
  CommandBarIntent intent;
  intent.row = row;
  intent.disposition = disposition;
  intent.event_flags = event_flags;
  intent.typed_text = typed_;
  intent.scope = scope_;
  intent.site_search_id = site_search_id_;

  base::WeakPtr<OpenCommandBarView> weak = weak_factory_.GetWeakPtr();
  delegate_->OnCommandBarIntent(intent);
  if (!weak || !presented_) {
    return;
  }
  if (disposition == CommandBarDisposition::kNewBackgroundTab) {
    // The bar stays open with its text selected, so the next entry replaces
    // it (Arc 1.172 s2 11-returns).
    typed_ += completion_;
    completion_.clear();
    field_->SelectAll(false);
    return;
  }
  Dismiss(CommandBarDismissReason::kCommitted);
}

// --- Geometry ----------------------------------------------------------------

void OpenCommandBarView::UpdateCard() {
  const size_t rows = mode_ == CommandBarMode::kLittleOpen
                          ? m::kMaxVisibleRows
                          : results_.rows.size();
  card_ = ComputeCardBounds(size(), mode_, rows, inline_anchor_);
}

gfx::Rect OpenCommandBarView::ChipRect() const {
  if (scope_ == CommandBarScope::kNone) {
    return gfx::Rect();
  }
  const CardLayout& l = LayoutFor(is_inline());
  const int text = secondary::TextWidth(
      scope_title_, secondary::FontOfSize(13, gfx::Font::Weight::MEDIUM));
  return gfx::Rect(card_.x() + l.text_x(),
                   card_.y() + (l.input_height - m::kChipHeight) / 2,
                   text + 2 * m::kChipPaddingX, m::kChipHeight);
}

int OpenCommandBarView::HintWidth() const {
  if (scope_ != CommandBarScope::kNone || !results_.site_search_hint) {
    return 0;
  }
  const gfx::FontList font = secondary::FontOfSize(kHintFontSize);
  const CommandBarScopeTarget& hint = *results_.site_search_hint;
  int width = secondary::TextWidth(u"Search " + hint.title, font) +
              kHintLabelGap + secondary::TextWidth(u"Tab", font) +
              2 * kInputKeycapPadding;
  if (hint.exact_keyword) {
    width += kHintKeyGap + secondary::TextWidth(u"or", font) + kHintKeyGap +
             secondary::TextWidth(u"Space", font) + 2 * kInputKeycapPadding;
  }
  return width + kHintLabelGap;
}

void OpenCommandBarView::Layout(PassKey) {
  UpdateCard();
  const CardLayout& l = LayoutFor(is_inline());
  const gfx::Rect chip = ChipRect();
  const int field_x =
      chip.IsEmpty() ? card_.x() + l.text_x() : chip.right() + m::kChipToText;
  const int right = card_.right() - l.padding_right - HintWidth() -
                    (mode_ == CommandBarMode::kLittleOpen
                         ? m::kLittleOpenCloseTrailing - l.padding_right
                         : 0);
  const int field_h = field_->GetFontList().GetHeight() + 6;
  field_->SetBoundsRect(gfx::Rect(field_x,
                                  card_.y() + (l.input_height - field_h) / 2,
                                  std::max(0, right - field_x), field_h));
  if (mode_ == CommandBarMode::kLittleOpen) {
    close_button_->SetBoundsRect(
        gfx::Rect(card_.right() - m::kLittleOpenCloseTrailing,
                  card_.y() + m::kLittleOpenCloseY, m::kLittleOpenCloseSize,
                  m::kLittleOpenCloseSize));
  }
}

gfx::Rect OpenCommandBarView::RowRect(size_t visible_index) const {
  const CardLayout& l = LayoutFor(is_inline());
  return gfx::Rect(
      card_.x() + l.list_padding_x,
      card_.y() + l.list_top() + static_cast<int>(visible_index) * l.row_pitch,
      card_.width() - 2 * l.list_padding_x, l.row_height);
}

std::optional<size_t> OpenCommandBarView::RowAt(const gfx::Point& point) const {
  const size_t visible = std::min<size_t>(
      results_.rows.size() - std::min(scroll_, results_.rows.size()),
      m::kMaxVisibleRows);
  for (size_t i = 0; i < visible; ++i) {
    // Hit area covers the 4 pt gap below each row so no dead stripes.
    gfx::Rect hit = RowRect(i);
    hit.set_height(LayoutFor(is_inline()).row_pitch);
    if (hit.Contains(point)) {
      return scroll_ + i;
    }
  }
  return std::nullopt;
}

// --- Colors ------------------------------------------------------------------

SkColor OpenCommandBarView::body_color() const {
  return appearance_.dark ? kBodyDark : kBodyLight;
}

SkColor OpenCommandBarView::text_color() const {
  return appearance_.dark ? kTextDark : kTextLight;
}

SkColor OpenCommandBarView::secondary_text_color() const {
  return secondary::WithAlpha(text_color(), kSecondaryAlpha);
}

SkColor OpenCommandBarView::selection_fill() const {
  // Inside a scope the selected row takes the chip color (S2 18/0018).
  return scope_ == CommandBarScope::kNone ? appearance_.ActiveAccent()
                                          : m::kScopeChipColor;
}

// --- Painting ----------------------------------------------------------------

void OpenCommandBarView::OnPaint(gfx::Canvas* canvas) {
  if (!presented_) {
    return;
  }
  const bool little_open = mode_ == CommandBarMode::kLittleOpen;
  if (!little_open && !is_inline()) {
    canvas->FillRect(GetLocalBounds(),
                     secondary::WithAlpha(SK_ColorBLACK, kScrimAlpha));
  }
  const gfx::RectF card(card_);
  if (little_open) {
    secondary::FillRoundRect(canvas, card, m::kCornerRadius, body_color());
  } else {
    secondary::FillRoundRectWithShadow(
        canvas, card, m::kCornerRadius, body_color(),
        secondary::WithAlpha(SK_ColorBLACK, kShadowAlpha), kShadowOffsetY,
        kShadowBlur);
    // Dark inline editor: a light hairline so the card reads as raised over
    // a dark sidebar (CommandCard.inlineDarkHairline, guess).
    const SkColor hairline = is_inline() && appearance_.dark
                                 ? secondary::WithAlpha(SK_ColorWHITE, 0.16f)
                                 : secondary::WithAlpha(SK_ColorBLACK, 0.22f);
    secondary::StrokeRoundRect(canvas, card, m::kCornerRadius, hairline,
                               kHairlineWidth);
  }

  canvas->Save();
  canvas->ClipRect(card_);
  PaintInputRow(canvas);
  PaintRows(canvas);
  canvas->Restore();
}

void OpenCommandBarView::PaintInputRow(gfx::Canvas* canvas) {
  const CardLayout& l = LayoutFor(is_inline());
  // Leading icon follows row 1: its favicon, the globe for a URL without
  // one, the magnifier for searches and an empty field (§3.3). Cmd+L shows
  // the page's favicon until the user types.
  const gfx::Rect icon(card_.x() + l.icon_x,
                       card_.y() + (l.input_height - l.icon_size) / 2,
                       l.icon_size, l.icon_size);
  const CommandBarRow* first =
      results_.rows.empty() ? nullptr : &results_.rows.front();
  if (mode_ == CommandBarMode::kEditCurrentUrl && !current_favicon_.isNull() &&
      !last_edit_was_insertion_ && typed_ == field_->GetText()) {
    secondary::DrawImageInRect(canvas, current_favicon_, icon);
  } else if (first && !typed_.empty() && !first->icon.isNull() &&
             IsPageLike(first->kind)) {
    secondary::DrawImageInRect(canvas, first->icon, icon);
  } else {
    const Glyph glyph = first && !typed_.empty() &&
                                (first->kind == CommandBarRowKind::kNavigate ||
                                 first->kind == CommandBarRowKind::kHistory)
                            ? Glyph::kGlobe
                            : Glyph::kSearch;
    secondary::PaintGlyph(canvas, glyph, gfx::RectF(icon),
                          secondary_text_color());
  }

  // Scope chip with its glow (CC-41).
  const gfx::Rect chip = ChipRect();
  if (!chip.IsEmpty()) {
    secondary::FillRoundRectWithShadow(
        canvas, gfx::RectF(chip), m::kChipHeight / 2.f, m::kScopeChipColor,
        secondary::WithAlpha(m::kScopeChipColor, 0.32f), 0.f, 16.f);
    secondary::DrawText(canvas, scope_title_,
                        secondary::FontOfSize(13, gfx::Font::Weight::MEDIUM),
                        SK_ColorWHITE, chip, gfx::Canvas::TEXT_ALIGN_CENTER);
  }

  // Trailing Site Search hint: "Search <Site>  [Tab]" or "… [Tab] or [Space]".
  if (const int hint_width = HintWidth(); hint_width > 0) {
    const gfx::FontList font = secondary::FontOfSize(kHintFontSize);
    const CommandBarScopeTarget& hint = *results_.site_search_hint;
    const int keycap_y = card_.y() + (l.input_height - kInputKeycapHeight) / 2;
    int x = card_.right() - kHintTrailing - hint_width + kHintLabelGap;
    auto draw_label = [&](const std::u16string& text) {
      const int w = secondary::TextWidth(text, font);
      secondary::DrawText(canvas, text, font, secondary_text_color(),
                          gfx::Rect(x, keycap_y, w, kInputKeycapHeight));
      x += w;
    };
    auto draw_keycap = [&](const std::u16string& text) {
      const int w = secondary::TextWidth(text, font) + 2 * kInputKeycapPadding;
      const gfx::Rect cap(x, keycap_y, w, kInputKeycapHeight);
      secondary::FillRoundRect(canvas, gfx::RectF(cap), kKeyCapRadius,
                               secondary::WithAlpha(text_color(), 0.06f));
      secondary::DrawText(canvas, text, font, secondary_text_color(), cap,
                          gfx::Canvas::TEXT_ALIGN_CENTER);
      x += w;
    };
    draw_label(u"Search " + hint.title);
    x += kHintLabelGap;
    draw_keycap(u"Tab");
    if (hint.exact_keyword) {
      x += kHintKeyGap;
      draw_label(u"or");
      x += kHintKeyGap;
      draw_keycap(u"Space");
    }
  }

  // Separator under the input row when rows show.
  if (!results_.rows.empty()) {
    const SkColor separator = appearance_.dark
                                  ? secondary::WithAlpha(SK_ColorWHITE, 0.09f)
                                  : secondary::WithAlpha(SK_ColorBLACK, 0.08f);
    canvas->FillRect(
        gfx::Rect(card_.x(), card_.y() + l.input_height, card_.width(), 1),
        separator);
  }
}

void OpenCommandBarView::PaintRows(gfx::Canvas* canvas) {
  const size_t first = std::min(scroll_, results_.rows.size());
  const size_t count =
      std::min<size_t>(results_.rows.size() - first, m::kMaxVisibleRows);
  for (size_t i = 0; i < count; ++i) {
    PaintRow(canvas, results_.rows[first + i], RowRect(i),
             first + i == selected_);
  }
}

void OpenCommandBarView::PaintRow(gfx::Canvas* canvas,
                                  const CommandBarRow& row,
                                  const gfx::Rect& rect,
                                  bool selected) {
  const CardLayout& l = LayoutFor(is_inline());
  if (selected) {
    secondary::FillRoundRect(canvas, gfx::RectF(rect), kRowRadius,
                             selection_fill());
  }
  const SkColor title_color = selected ? SK_ColorWHITE : text_color();
  const SkColor subtitle_color = selected
                                     ? secondary::WithAlpha(SK_ColorWHITE, 0.8f)
                                     : secondary_text_color();

  // Icon: 18 pt box; the selected row puts it on a white 24 pt tile.
  const gfx::Rect icon_box(rect.x() + l.row_padding_left,
                           rect.y() + (rect.height() - kRowIconSize) / 2,
                           kRowIconSize, kRowIconSize);
  const gfx::Rect tile(icon_box.CenterPoint().x() - kTileSize / 2,
                       icon_box.CenterPoint().y() - kTileSize / 2, kTileSize,
                       kTileSize);
  if (row.kind == CommandBarRowKind::kSwitchToSplit &&
      !row.pane_icons.empty()) {
    // One cell per pane on a plate, 1 pt gaps (CC-13).
    secondary::FillRoundRect(
        canvas, gfx::RectF(tile), kTileRadius,
        selected ? SK_ColorWHITE : secondary::WithAlpha(text_color(), 0.05f));
    const int n = static_cast<int>(std::min<size_t>(row.pane_icons.size(), 4));
    const int cell_w = (tile.width() - (n - 1)) / n;
    for (int i = 0; i < n; ++i) {
      const gfx::Rect cell(tile.x() + i * (cell_w + 1), tile.y(), cell_w,
                           tile.height());
      const int icon = std::min(9, cell_w);
      secondary::DrawImageInRect(
          canvas, row.pane_icons[i],
          gfx::Rect(cell.CenterPoint().x() - icon / 2,
                    cell.CenterPoint().y() - icon / 2, icon, icon));
    }
  } else if (!row.icon.isNull()) {
    if (selected) {
      secondary::FillRoundRect(canvas, gfx::RectF(tile), kTileRadius,
                               SK_ColorWHITE);
    }
    secondary::DrawImageInRect(
        canvas, row.icon,
        gfx::Rect(tile.CenterPoint().x() - kTileFavicon / 2,
                  tile.CenterPoint().y() - kTileFavicon / 2, kTileFavicon,
                  kTileFavicon));
  } else {
    secondary::FillRoundRect(
        canvas, gfx::RectF(tile), kTileRadius,
        selected ? SK_ColorWHITE : secondary::WithAlpha(text_color(), 0.05f));
    secondary::PaintGlyph(canvas, row.fallback_glyph,
                          gfx::RectF(tile.CenterPoint().x() - 7.f,
                                     tile.CenterPoint().y() - 7.f, 14.f, 14.f),
                          selected ? selection_fill() : secondary_text_color());
  }

  // Right side: badge + arrow key cap, or action keycaps.
  const gfx::FontList hint_font =
      secondary::FontOfSize(kHintFontSize, gfx::Font::Weight::SEMIBOLD);
  int right = rect.right() - l.row_padding_right;
  const int cap_y = rect.y() + (rect.height() - kKeyCapSize) / 2;
  const SkColor cap_fill =
      selected ? SK_ColorWHITE : secondary::WithAlpha(text_color(), 0.05f);
  const SkColor cap_ink = selected ? selection_fill() : secondary_text_color();
  if (!row.keycaps.empty()) {
    for (auto it = row.keycaps.rbegin(); it != row.keycaps.rend(); ++it) {
      const int w =
          std::max(kKeyCapSize, secondary::TextWidth(*it, hint_font) + 8);
      const gfx::Rect cap(right - w, cap_y, w, kKeyCapSize);
      secondary::FillRoundRect(canvas, gfx::RectF(cap), kKeyCapRadius,
                               cap_fill);
      secondary::DrawText(canvas, *it, hint_font, cap_ink, cap,
                          gfx::Canvas::TEXT_ALIGN_CENTER);
      right = cap.x() - 4;
    }
    right -= kHintGap;
  } else if (!row.badge.empty()) {
    const gfx::Rect cap(right - kKeyCapSize, cap_y, kKeyCapSize, kKeyCapSize);
    secondary::FillRoundRect(canvas, gfx::RectF(cap), kKeyCapRadius, cap_fill);
    secondary::PaintGlyph(canvas, Glyph::kForward,
                          gfx::RectF(cap.x() + 4.f, cap.y() + 4.f, 12.f, 12.f),
                          cap_ink);
    const int w = secondary::TextWidth(row.badge, hint_font);
    const int label_x = cap.x() - kHintGap - w;
    secondary::DrawText(canvas, row.badge, hint_font,
                        selected ? SK_ColorWHITE : secondary_text_color(),
                        gfx::Rect(label_x, rect.y(), w, rect.height()));
    right = label_x - kHintGap;
  }

  // Title, then "— subtitle" 4 pt after the title's whole-point width.
  const gfx::FontList title_font =
      secondary::FontOfSize(l.row_font, selected ? gfx::Font::Weight::SEMIBOLD
                                                 : gfx::Font::Weight::MEDIUM);
  const int title_x = rect.x() + l.title_x();
  const int title_room = std::max(0, right - title_x);
  const int title_w = std::min({secondary::TextWidth(row.title, title_font),
                                kTitleMaxWidth, title_room});
  secondary::DrawText(canvas, row.title, title_font, title_color,
                      gfx::Rect(title_x, rect.y(), title_w, rect.height()));
  if (!row.subtitle.empty()) {
    const int sub_x = title_x + title_w + kSubtitleGap;
    const int sub_w = std::max(0, right - sub_x);
    secondary::DrawText(canvas, u"— " + row.subtitle,
                        secondary::FontOfSize(l.row_font), subtitle_color,
                        gfx::Rect(sub_x, rect.y(), sub_w, rect.height()));
  }
}

// --- Mouse -------------------------------------------------------------------

bool OpenCommandBarView::OnMousePressed(const ui::MouseEvent& event) {
  if (!presented_) {
    return false;
  }
  if (!card_.Contains(event.location())) {
    // Outside: close. The delegate gets the point so a click on a sidebar
    // tab also selects it.
    DismissInternal(CommandBarDismissReason::kClickOutside, event.location());
    return true;
  }
  if (std::optional<size_t> row = RowAt(event.location())) {
    selected_ = *row;
    Commit(*row, event.flags());
    return true;
  }
  field_->RequestFocus();
  return true;
}

void OpenCommandBarView::OnMouseMoved(const ui::MouseEvent& event) {
  // Real pointer moves only: rows sliding under a still pointer do not
  // select (commandbar.md §4).
  if (last_mouse_ == event.location()) {
    return;
  }
  last_mouse_ = event.location();
  if (std::optional<size_t> row = RowAt(event.location());
      row && *row != selected_) {
    selected_ = *row;
    user_moved_selection_ = true;
    UpdateCompletion();
    SchedulePaint();
  }
}

bool OpenCommandBarView::OnMouseWheel(const ui::MouseWheelEvent& event) {
  if (results_.rows.size() <= m::kMaxVisibleRows) {
    return true;
  }
  const size_t max_scroll = results_.rows.size() - m::kMaxVisibleRows;
  if (event.y_offset() > 0 && scroll_ > 0) {
    --scroll_;
  } else if (event.y_offset() < 0 && scroll_ < max_scroll) {
    ++scroll_;
  }
  SchedulePaint();
  return true;
}

BEGIN_METADATA(OpenCommandBarView)
END_METADATA

}  // namespace open_unified
