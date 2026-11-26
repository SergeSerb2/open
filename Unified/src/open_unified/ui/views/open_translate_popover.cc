// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/ui/views/open_translate_popover.h"

#include <algorithm>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/models/simple_combobox_model.h"
#include "ui/base/mojom/dialog_button.mojom.h"
#include "ui/base/mojom/menu_source_type.mojom.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/bubble/bubble_border.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/controls/button/checkbox.h"
#include "ui/views/controls/combobox/combobox.h"
#include "ui/views/controls/label.h"
#include "ui/views/controls/menu/menu_runner.h"
#include "ui/views/controls/scroll_view.h"

namespace open_unified {

namespace {

namespace m = translate_metrics;

constexpr int kMenuAlwaysTranslate = 1001;
constexpr int kMenuNeverTranslateHost = 1002;
constexpr int kMenuLanguageSettings = 1003;

// Open brand blue (#3139FB) matching TranslatePopoverView.swift.
constexpr SkColor kBrandBlue = SkColorSetRGB(0x31, 0x39, 0xFB);

std::optional<size_t> FindLanguageIndex(
    const std::vector<TranslateLanguageOption>& langs,
    const std::string& code) {
  const std::string lower = base::ToLowerASCII(code);
  for (size_t i = 0; i < langs.size(); ++i) {
    if (base::ToLowerASCII(langs[i].code) == lower) {
      return i;
    }
  }
  // Match base language subtag (e.g. "en-US" -> "en") when not zh-CN/zh-TW.
  const size_t dash = lower.find('-');
  if (dash != std::string::npos) {
    const std::string prefix = lower.substr(0, dash);
    for (size_t i = 0; i < langs.size(); ++i) {
      if (base::ToLowerASCII(langs[i].code) == prefix) {
        return i;
      }
    }
  }
  return std::nullopt;
}

std::vector<ui::SimpleComboboxModel::Item> ToComboboxItems(
    const std::vector<TranslateLanguageOption>& langs) {
  std::vector<ui::SimpleComboboxModel::Item> items;
  items.reserve(langs.size());
  for (const auto& lang : langs) {
    items.emplace_back(lang.name);
  }
  return items;
}

}  // namespace

// ===========================================================================
// Canonical Language Catalog (Top 25 + Auto-detect)
// ===========================================================================

std::vector<TranslateLanguageOption> DefaultTranslateTargetLanguages() {
  return {
      {"en", u"English"},
      {"es", u"Spanish"},
      {"fr", u"French"},
      {"de", u"German"},
      {"it", u"Italian"},
      {"pt", u"Portuguese"},
      {"nl", u"Dutch"},
      {"ru", u"Russian"},
      {"zh-CN", u"Chinese (Simplified)"},
      {"zh-TW", u"Chinese (Traditional)"},
      {"ja", u"Japanese"},
      {"ko", u"Korean"},
      {"ar", u"Arabic"},
      {"hi", u"Hindi"},
      {"tr", u"Turkish"},
      {"pl", u"Polish"},
      {"sv", u"Swedish"},
      {"da", u"Danish"},
      {"no", u"Norwegian"},
      {"fi", u"Finnish"},
      {"uk", u"Ukrainian"},
      {"vi", u"Vietnamese"},
      {"th", u"Thai"},
      {"id", u"Indonesian"},
      {"cs", u"Czech"},
  };
}

std::vector<TranslateLanguageOption> DefaultTranslateSourceLanguages() {
  std::vector<TranslateLanguageOption> list;
  list.push_back({"auto", u"Auto-detect"});
  auto targets = DefaultTranslateTargetLanguages();
  list.insert(list.end(), targets.begin(), targets.end());
  return list;
}

std::u16string TranslateLanguageDisplayName(const std::string& code) {
  if (code.empty() || code == "auto" || code == "und") {
    return u"Auto-detect";
  }
  const auto langs = DefaultTranslateTargetLanguages();
  if (auto idx = FindLanguageIndex(langs, code)) {
    return langs[*idx].name;
  }
  return base::UTF8ToUTF16(code);
}

// ===========================================================================
// TranslatePopoverState
// ===========================================================================

TranslatePopoverState::TranslatePopoverState() = default;
TranslatePopoverState::TranslatePopoverState(const TranslatePopoverState&) =
    default;
TranslatePopoverState::TranslatePopoverState(
    TranslatePopoverState&&) noexcept = default;
TranslatePopoverState& TranslatePopoverState::operator=(
    const TranslatePopoverState&) = default;
TranslatePopoverState& TranslatePopoverState::operator=(
    TranslatePopoverState&&) noexcept = default;
TranslatePopoverState::~TranslatePopoverState() = default;

// ===========================================================================
// OpenTranslatePopoverView
// ===========================================================================

OpenTranslatePopoverView::OpenTranslatePopoverView(
    TranslatePopoverDelegate* delegate,
    const TranslatePopoverState& state,
    const secondary::Appearance& appearance)
    : delegate_(delegate), state_(state), appearance_(appearance) {
  GetViewAccessibility().SetRole(ax::mojom::Role::kDialog);
  GetViewAccessibility().SetName(u"Translate");
  PopulateLanguageListsIfEmpty();
  Rebuild();
}

OpenTranslatePopoverView::~OpenTranslatePopoverView() = default;

void OpenTranslatePopoverView::SetState(const TranslatePopoverState& state) {
  state_ = state;
  PopulateLanguageListsIfEmpty();
  Rebuild();
  PreferredSizeChanged();
  InvalidateLayout();
  SchedulePaint();
}

SkColor OpenTranslatePopoverView::panel_color() const {
  return appearance_.dark ? SkColorSetRGB(0x23, 0x24, 0x2B)
                          : SkColorSetRGB(0xFA, 0xFA, 0xFC);
}

gfx::Size OpenTranslatePopoverView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  const int width =
      state_.mode == TranslatePopoverMode::kSelection ? m::kSelectionWidth
                                                      : m::kWidth;
  const int content_w = width - 2 * m::kPadding;
  int y = m::kPadding;

  if (title_label_) {
    y += title_label_->GetHeightForWidth(content_w);
  }

  if (state_.mode == TranslatePopoverMode::kSelection) {
    if (target_combobox_) {
      y += m::kSmallGap + m::kDropdownHeight;
    }
    if (selection_scroll_ && selection_result_label_) {
      const int text_h =
          selection_result_label_->GetHeightForWidth(content_w - 8);
      y += m::kRowGap + std::clamp(text_h + 8, 32, m::kSelectionMaxHeight);
    }
    if (error_label_) {
      y += m::kSmallGap + error_label_->GetHeightForWidth(content_w);
    }
    y += m::kRowGap + m::kButtonHeight + m::kPadding;
    return gfx::Size(width, y);
  }

  // Page mode: dropdown row, optional error, option checkboxes, action row.
  y += m::kRowGap + m::kDropdownHeight;
  if (error_label_) {
    y += m::kSmallGap + error_label_->GetHeightForWidth(content_w);
  }
  if (always_translate_checkbox_) {
    y += m::kSmallGap +
         always_translate_checkbox_->GetPreferredSize({}).height();
  }
  if (never_translate_checkbox_) {
    y += m::kSmallGap +
         never_translate_checkbox_->GetPreferredSize({}).height();
  }
  y += m::kRowGap + m::kButtonHeight + m::kPadding;
  return gfx::Size(width, y);
}

void OpenTranslatePopoverView::Layout(PassKey) {
  const int width = GetLocalBounds().width();
  const int content_w = std::max(0, width - 2 * m::kPadding);
  int y = m::kPadding;

  if (title_label_) {
    const int h = title_label_->GetHeightForWidth(content_w);
    title_label_->SetBoundsRect(gfx::Rect(m::kPadding, y, content_w, h));
    y += h;
  }

  if (state_.mode == TranslatePopoverMode::kSelection) {
    if (target_combobox_) {
      y += m::kSmallGap;
      target_combobox_->SetBoundsRect(
          gfx::Rect(m::kPadding, y, content_w, m::kDropdownHeight));
      y += m::kDropdownHeight;
    }
    if (selection_scroll_ && selection_result_label_) {
      y += m::kRowGap;
      const int text_w = std::max(0, content_w - 8);
      const int text_h = selection_result_label_->GetHeightForWidth(text_w);
      selection_result_label_->SetBoundsRect(gfx::Rect(0, 0, text_w, text_h));
      const int scroll_h = std::clamp(text_h + 8, 32, m::kSelectionMaxHeight);
      selection_scroll_->SetBoundsRect(
          gfx::Rect(m::kPadding, y, content_w, scroll_h));
      y += scroll_h;
    }
    if (error_label_) {
      y += m::kSmallGap;
      const int h = error_label_->GetHeightForWidth(content_w);
      error_label_->SetBoundsRect(gfx::Rect(m::kPadding, y, content_w, h));
      y += h;
    }
    y += m::kRowGap;
    int x = m::kPadding;
    if (primary_button_) {
      const int pw = 76;
      primary_button_->SetBoundsRect(gfx::Rect(x, y, pw, m::kButtonHeight));
      x += pw + m::kButtonGap;
    }
    if (secondary_button_) {
      const int sw = 128;
      secondary_button_->SetBoundsRect(gfx::Rect(x, y, sw, m::kButtonHeight));
    }
    return;
  }

  // Page mode layout: Source -> Target dropdowns.
  if (source_combobox_ && arrow_label_ && target_combobox_) {
    y += m::kRowGap;
    const int combo_w = std::max(60, (content_w - m::kArrowWidth) / 2);
    source_combobox_->SetBoundsRect(
        gfx::Rect(m::kPadding, y, combo_w, m::kDropdownHeight));
    arrow_label_->SetBoundsRect(
        gfx::Rect(m::kPadding + combo_w, y, m::kArrowWidth, m::kDropdownHeight));
    target_combobox_->SetBoundsRect(
        gfx::Rect(m::kPadding + combo_w + m::kArrowWidth, y,
                  content_w - combo_w - m::kArrowWidth, m::kDropdownHeight));
    y += m::kDropdownHeight;
  }

  if (error_label_) {
    y += m::kSmallGap;
    const int h = error_label_->GetHeightForWidth(content_w);
    error_label_->SetBoundsRect(gfx::Rect(m::kPadding, y, content_w, h));
    y += h;
  }

  if (always_translate_checkbox_) {
    y += m::kSmallGap;
    const int h = always_translate_checkbox_->GetPreferredSize({}).height();
    always_translate_checkbox_->SetBoundsRect(
        gfx::Rect(m::kPadding, y, content_w, h));
    y += h;
  }

  if (never_translate_checkbox_) {
    y += m::kSmallGap;
    const int h = never_translate_checkbox_->GetPreferredSize({}).height();
    never_translate_checkbox_->SetBoundsRect(
        gfx::Rect(m::kPadding, y, content_w, h));
    y += h;
  }

  y += m::kRowGap;
  int x = m::kPadding;
  if (primary_button_) {
    const std::u16string primary_title =
        state_.mode == TranslatePopoverMode::kTranslated
            ? u"Show Original"
            : (state_.mode == TranslatePopoverMode::kTranslating
                   ? u"Translating\u2026"
                   : u"Translate");
    const gfx::FontList font =
        secondary::FontOfSize(m::kBodyFontSize, gfx::Font::Weight::MEDIUM);
    const int pw =
        secondary::TextWidth(primary_title, font) + 2 * m::kButtonPaddingX;
    primary_button_->SetBoundsRect(gfx::Rect(x, y, pw, m::kButtonHeight));
    x += pw + m::kButtonGap;
  }
  if (options_button_) {
    const gfx::FontList font =
        secondary::FontOfSize(m::kBodyFontSize, gfx::Font::Weight::MEDIUM);
    const int ow =
        secondary::TextWidth(u"Options", font) + 2 * m::kButtonPaddingX + 12;
    options_button_->SetBoundsRect(gfx::Rect(x, y, ow, m::kButtonHeight));
  }
}

void OpenTranslatePopoverView::OnPaint(gfx::Canvas* canvas) {
  canvas->FillRect(GetLocalBounds(), panel_color());
}

void OpenTranslatePopoverView::ExecuteCommand(int command_id, int event_flags) {
  if (!delegate_) {
    return;
  }
  switch (command_id) {
    case kMenuAlwaysTranslate: {
      const std::string src = SelectedSourceCode();
      if (!src.empty() && src != "auto" && src != "und") {
        state_.always_translate_source = !state_.always_translate_source;
        if (always_translate_checkbox_) {
          always_translate_checkbox_->SetChecked(
              state_.always_translate_source);
        }
        delegate_->OnAlwaysTranslateToggled(src, SelectedTargetCode(),
                                            state_.always_translate_source);
      }
      break;
    }
    case kMenuNeverTranslateHost: {
      if (!state_.host.empty()) {
        state_.never_translate_host = !state_.never_translate_host;
        if (never_translate_checkbox_) {
          never_translate_checkbox_->SetChecked(state_.never_translate_host);
        }
        delegate_->OnNeverTranslateHostToggled(state_.host,
                                               state_.never_translate_host);
      }
      break;
    }
    case kMenuLanguageSettings:
      delegate_->OnOpenLanguageSettings();
      break;
    default:
      break;
  }
}

bool OpenTranslatePopoverView::IsCommandIdChecked(int command_id) const {
  if (command_id == kMenuAlwaysTranslate) {
    return state_.always_translate_source;
  }
  if (command_id == kMenuNeverTranslateHost) {
    return state_.never_translate_host;
  }
  return false;
}

bool OpenTranslatePopoverView::IsCommandIdEnabled(int command_id) const {
  if (command_id == kMenuAlwaysTranslate) {
    const std::string src = SelectedSourceCode();
    return !src.empty() && src != "auto" && src != "und";
  }
  if (command_id == kMenuNeverTranslateHost) {
    return !state_.host.empty();
  }
  return true;
}

void OpenTranslatePopoverView::PopulateLanguageListsIfEmpty() {
  if (state_.source_languages.empty()) {
    state_.source_languages = DefaultTranslateSourceLanguages();
  }
  if (state_.target_languages.empty()) {
    state_.target_languages = DefaultTranslateTargetLanguages();
  }
}

void OpenTranslatePopoverView::Rebuild() {
  RemoveAllChildViews();
  title_label_ = nullptr;
  error_label_ = nullptr;
  source_combobox_ = nullptr;
  arrow_label_ = nullptr;
  target_combobox_ = nullptr;
  always_translate_checkbox_ = nullptr;
  never_translate_checkbox_ = nullptr;
  selection_scroll_ = nullptr;
  selection_result_label_ = nullptr;
  primary_button_ = nullptr;
  secondary_button_ = nullptr;
  options_button_ = nullptr;

  const std::u16string source_name =
      TranslateLanguageDisplayName(state_.source_lang);
  const std::u16string target_name =
      TranslateLanguageDisplayName(state_.target_lang);

  // Title label.
  std::u16string title_text = state_.title;
  if (title_text.empty()) {
    switch (state_.mode) {
      case TranslatePopoverMode::kOffer:
      case TranslatePopoverMode::kTranslating:
        title_text = u"Translate this page to " + target_name + u"?";
        break;
      case TranslatePopoverMode::kTranslated:
        title_text = u"Translated from " + source_name + u".";
        break;
      case TranslatePopoverMode::kSelection:
        title_text = (state_.source_lang.empty() || state_.source_lang == "auto"
                          ? u"Translate Selection"
                          : source_name + u" \u2192 " + target_name);
        break;
    }
  }

  auto title = std::make_unique<views::Label>(title_text);
  title->SetFontList(secondary::FontOfSize(
      state_.mode == TranslatePopoverMode::kSelection ? m::kMetaFontSize
                                                      : m::kTitleFontSize,
      gfx::Font::Weight::SEMIBOLD));
  title->SetEnabledColor(state_.mode == TranslatePopoverMode::kSelection
                             ? TextSecondary()
                             : TextPrimary());
  title->SetHorizontalAlignment(gfx::ALIGN_LEFT);
  title->SetMultiLine(true);
  title->SetAutoColorReadabilityEnabled(false);
  title_label_ = AddChildView(std::move(title));

  // Target language combobox (used in both Page and Selection modes).
  target_model_ = std::make_unique<ui::SimpleComboboxModel>(
      ToComboboxItems(state_.target_languages));
  auto target_cb = std::make_unique<views::Combobox>(target_model_.get());
  if (auto idx = FindLanguageIndex(state_.target_languages, state_.target_lang)) {
    target_cb->SetSelectedIndex(*idx);
  }
  target_cb->SetTooltipTextAndAccessibleName(u"Target language");
  target_cb->SetCallback(
      base::BindRepeating(&OpenTranslatePopoverView::OnTargetLanguageChanged,
                          base::Unretained(this)));

  if (state_.mode == TranslatePopoverMode::kSelection) {
    target_combobox_ = AddChildView(std::move(target_cb));

    auto scroll = std::make_unique<views::ScrollView>();
    scroll->SetHorizontalScrollBarMode(
        views::ScrollView::ScrollBarMode::kDisabled);
    scroll->SetDrawOverflowIndicator(false);
    scroll->SetBackgroundColor(std::nullopt);
    scroll->ClipHeightTo(32, m::kSelectionMaxHeight);

    const std::u16string body_text =
        state_.selection_loading
            ? u"Translating selection\u2026"
            : (!state_.translated_selection.empty()
                   ? state_.translated_selection
                   : (!state_.error.empty() ? state_.error
                                            : state_.selected_text));
    auto body = std::make_unique<views::Label>(body_text);
    body->SetFontList(
        secondary::FontOfSize(m::kBodyFontSize, gfx::Font::Weight::NORMAL));
    body->SetEnabledColor(
        (state_.selection_loading || state_.translated_selection.empty())
            ? TextSecondary()
            : TextPrimary());
    body->SetHorizontalAlignment(gfx::ALIGN_LEFT);
    body->SetMultiLine(true);
    body->SetSelectable(!state_.selection_loading &&
                        !state_.translated_selection.empty());
    body->SetAutoColorReadabilityEnabled(false);
    selection_result_label_ = scroll->SetContents(std::move(body));
    selection_scroll_ = AddChildView(std::move(scroll));

    if (!state_.error.empty() && !state_.translated_selection.empty()) {
      auto err = std::make_unique<views::Label>(state_.error);
      err->SetFontList(
          secondary::FontOfSize(m::kErrorFontSize, gfx::Font::Weight::NORMAL));
      err->SetEnabledColor(SkColorSetRGB(0xD9, 0x30, 0x25));
      err->SetHorizontalAlignment(gfx::ALIGN_LEFT);
      err->SetMultiLine(true);
      err->SetAutoColorReadabilityEnabled(false);
      error_label_ = AddChildView(std::move(err));
    }

    auto copy_btn = std::make_unique<secondary::PaintedButton>(
        base::BindRepeating(&OpenTranslatePopoverView::OnPrimaryButtonPressed,
                            base::Unretained(this)),
        base::BindRepeating(&OpenTranslatePopoverView::PaintPrimaryButton,
                            base::Unretained(this)),
        u"Copy");
    copy_btn->SetEnabled(!state_.selection_loading &&
                         !state_.translated_selection.empty());
    primary_button_ = AddChildView(std::move(copy_btn));

    auto page_btn = std::make_unique<secondary::PaintedButton>(
        base::BindRepeating(&OpenTranslatePopoverView::OnSecondaryButtonPressed,
                            base::Unretained(this)),
        base::BindRepeating(&OpenTranslatePopoverView::PaintSecondaryButton,
                            base::Unretained(this), u"Translate Page", false),
        u"Translate Page");
    secondary_button_ = AddChildView(std::move(page_btn));
    return;
  }

  // Page mode: Source -> Target dropdowns.
  source_model_ = std::make_unique<ui::SimpleComboboxModel>(
      ToComboboxItems(state_.source_languages));
  auto source_cb = std::make_unique<views::Combobox>(source_model_.get());
  if (auto idx = FindLanguageIndex(state_.source_languages, state_.source_lang)) {
    source_cb->SetSelectedIndex(*idx);
  }
  source_cb->SetTooltipTextAndAccessibleName(u"Source language");
  source_cb->SetCallback(
      base::BindRepeating(&OpenTranslatePopoverView::OnSourceLanguageChanged,
                          base::Unretained(this)));
  source_combobox_ = AddChildView(std::move(source_cb));

  auto arrow = std::make_unique<views::Label>(u"\u2192");
  arrow->SetFontList(
      secondary::FontOfSize(m::kBodyFontSize, gfx::Font::Weight::MEDIUM));
  arrow->SetEnabledColor(TextSecondary());
  arrow->SetHorizontalAlignment(gfx::ALIGN_CENTER);
  arrow->SetAutoColorReadabilityEnabled(false);
  arrow_label_ = AddChildView(std::move(arrow));

  target_combobox_ = AddChildView(std::move(target_cb));

  // Optional inline error message.
  if (!state_.error.empty()) {
    auto err = std::make_unique<views::Label>(state_.error);
    err->SetFontList(
        secondary::FontOfSize(m::kErrorFontSize, gfx::Font::Weight::NORMAL));
    err->SetEnabledColor(SkColorSetRGB(0xD9, 0x30, 0x25));
    err->SetHorizontalAlignment(gfx::ALIGN_LEFT);
    err->SetMultiLine(true);
    err->SetAutoColorReadabilityEnabled(false);
    error_label_ = AddChildView(std::move(err));
  }

  // "Always translate <lang>" checkbox (when source language is known).
  if (!state_.source_lang.empty() && state_.source_lang != "auto" &&
      state_.source_lang != "und") {
    auto always_cb = std::make_unique<views::Checkbox>(
        u"Always translate " + source_name,
        base::BindRepeating(
            &OpenTranslatePopoverView::OnAlwaysTranslateCheckboxPressed,
            base::Unretained(this)));
    always_cb->SetChecked(state_.always_translate_source);
    always_translate_checkbox_ = AddChildView(std::move(always_cb));
  }

  // "Never translate <host>" checkbox (when host is available).
  if (!state_.host.empty()) {
    auto never_cb = std::make_unique<views::Checkbox>(
        u"Never translate " + base::UTF8ToUTF16(state_.host),
        base::BindRepeating(
            &OpenTranslatePopoverView::OnNeverTranslateCheckboxPressed,
            base::Unretained(this)));
    never_cb->SetChecked(state_.never_translate_host);
    never_translate_checkbox_ = AddChildView(std::move(never_cb));
  }

  // Primary action ("Translate" / "Show Original") + "Options ▾".
  const std::u16string primary_accessible =
      state_.mode == TranslatePopoverMode::kTranslated ? u"Show Original"
                                                       : u"Translate";
  auto primary = std::make_unique<secondary::PaintedButton>(
      base::BindRepeating(&OpenTranslatePopoverView::OnPrimaryButtonPressed,
                          base::Unretained(this)),
      base::BindRepeating(&OpenTranslatePopoverView::PaintPrimaryButton,
                          base::Unretained(this)),
      primary_accessible);
  primary->SetEnabled(state_.mode != TranslatePopoverMode::kTranslating);
  primary_button_ = AddChildView(std::move(primary));

  auto options = std::make_unique<secondary::PaintedButton>(
      base::BindRepeating(&OpenTranslatePopoverView::OnOptionsButtonPressed,
                          base::Unretained(this)),
      base::BindRepeating(&OpenTranslatePopoverView::PaintSecondaryButton,
                          base::Unretained(this), u"Options", true),
      u"Options");
  options_button_ = AddChildView(std::move(options));
}

std::string OpenTranslatePopoverView::SelectedSourceCode() const {
  if (source_combobox_) {
    if (auto idx = source_combobox_->GetSelectedIndex();
        idx.has_value() && *idx < state_.source_languages.size()) {
      return state_.source_languages[*idx].code;
    }
  }
  return state_.source_lang;
}

std::string OpenTranslatePopoverView::SelectedTargetCode() const {
  if (target_combobox_) {
    if (auto idx = target_combobox_->GetSelectedIndex();
        idx.has_value() && *idx < state_.target_languages.size()) {
      return state_.target_languages[*idx].code;
    }
  }
  return state_.target_lang;
}

void OpenTranslatePopoverView::OnSourceLanguageChanged() {
  state_.source_lang = SelectedSourceCode();
  if (state_.mode == TranslatePopoverMode::kTranslated && delegate_) {
    delegate_->OnTranslateRequested(state_.source_lang, SelectedTargetCode());
  }
}

void OpenTranslatePopoverView::OnTargetLanguageChanged() {
  state_.target_lang = SelectedTargetCode();
  if (!delegate_) {
    return;
  }
  if (state_.mode == TranslatePopoverMode::kSelection) {
    delegate_->OnSelectionTargetLanguageChanged(state_.target_lang);
  } else if (state_.mode == TranslatePopoverMode::kTranslated) {
    delegate_->OnTranslateRequested(SelectedSourceCode(), state_.target_lang);
  }
}

void OpenTranslatePopoverView::OnPrimaryButtonPressed() {
  if (!delegate_) {
    return;
  }
  if (state_.mode == TranslatePopoverMode::kSelection) {
    if (!state_.translated_selection.empty()) {
      delegate_->OnCopyTranslatedSelection(state_.translated_selection);
    }
    return;
  }
  if (state_.mode == TranslatePopoverMode::kTranslated) {
    delegate_->OnShowOriginalRequested();
  } else if (state_.mode != TranslatePopoverMode::kTranslating) {
    delegate_->OnTranslateRequested(SelectedSourceCode(), SelectedTargetCode());
  }
}

void OpenTranslatePopoverView::OnSecondaryButtonPressed() {
  if (!delegate_) {
    return;
  }
  if (state_.mode == TranslatePopoverMode::kSelection) {
    delegate_->OnTranslateRequested(state_.source_lang, SelectedTargetCode());
  }
}

void OpenTranslatePopoverView::OnOptionsButtonPressed() {
  ShowOptionsMenu();
}

void OpenTranslatePopoverView::OnAlwaysTranslateCheckboxPressed() {
  if (!always_translate_checkbox_ || !delegate_) {
    return;
  }
  state_.always_translate_source = always_translate_checkbox_->GetChecked();
  delegate_->OnAlwaysTranslateToggled(SelectedSourceCode(),
                                      SelectedTargetCode(),
                                      state_.always_translate_source);
}

void OpenTranslatePopoverView::OnNeverTranslateCheckboxPressed() {
  if (!never_translate_checkbox_ || !delegate_) {
    return;
  }
  state_.never_translate_host = never_translate_checkbox_->GetChecked();
  delegate_->OnNeverTranslateHostToggled(state_.host,
                                         state_.never_translate_host);
}

void OpenTranslatePopoverView::ShowOptionsMenu() {
  if (!options_button_ || !GetWidget()) {
    return;
  }
  options_menu_model_ = std::make_unique<ui::SimpleMenuModel>(this);
  const std::string src = SelectedSourceCode();
  if (!src.empty() && src != "auto" && src != "und") {
    options_menu_model_->AddCheckItem(
        kMenuAlwaysTranslate,
        u"Always translate " + TranslateLanguageDisplayName(src));
  }
  if (!state_.host.empty()) {
    options_menu_model_->AddCheckItem(
        kMenuNeverTranslateHost,
        u"Never translate " + base::UTF8ToUTF16(state_.host));
  }
  if (options_menu_model_->GetItemCount() > 0) {
    options_menu_model_->AddSeparator(ui::NORMAL_SEPARATOR);
  }
  options_menu_model_->AddItem(kMenuLanguageSettings,
                               u"Language Settings\u2026");

  options_menu_runner_ = std::make_unique<views::MenuRunner>(
      options_menu_model_.get(), views::MenuRunner::HAS_MNEMONICS);
  const gfx::Rect anchor = options_button_->GetBoundsInScreen();
  options_menu_runner_->RunMenuAt(
      GetWidget(), nullptr, anchor, views::MenuAnchorPosition::kTopLeft,
      ui::mojom::MenuSourceType::kMouse);
}

void OpenTranslatePopoverView::PaintPrimaryButton(gfx::Canvas* canvas,
                                                  const gfx::Rect& bounds,
                                                  bool hovered) {
  const bool enabled = primary_button_ ? primary_button_->GetEnabled() : true;
  const float alpha = !enabled ? 0.45f : (hovered ? 0.88f : 1.0f);
  secondary::FillRoundRect(canvas, gfx::RectF(bounds), m::kButtonRadius,
                           secondary::WithAlpha(kBrandBlue, alpha));
  std::u16string label;
  if (state_.mode == TranslatePopoverMode::kSelection) {
    label = u"Copy";
  } else if (state_.mode == TranslatePopoverMode::kTranslated) {
    label = u"Show Original";
  } else if (state_.mode == TranslatePopoverMode::kTranslating) {
    label = u"Translating\u2026";
  } else {
    label = u"Translate";
  }
  const gfx::FontList font =
      secondary::FontOfSize(m::kBodyFontSize, gfx::Font::Weight::MEDIUM);
  secondary::DrawText(canvas, label, font, SK_ColorWHITE, bounds,
                      gfx::Canvas::TEXT_ALIGN_CENTER);
}

void OpenTranslatePopoverView::PaintSecondaryButton(std::u16string label,
                                                    bool show_chevron,
                                                    gfx::Canvas* canvas,
                                                    const gfx::Rect& bounds,
                                                    bool hovered) {
  const SkColor fill =
      hovered ? (appearance_.dark ? secondary::WithAlpha(SK_ColorWHITE, 0.12f)
                                  : secondary::WithAlpha(SK_ColorBLACK, 0.08f))
              : (appearance_.dark ? secondary::WithAlpha(SK_ColorWHITE, 0.06f)
                                  : secondary::WithAlpha(SK_ColorBLACK, 0.04f));
  secondary::FillRoundRect(canvas, gfx::RectF(bounds), m::kButtonRadius, fill);

  const gfx::FontList font =
      secondary::FontOfSize(m::kBodyFontSize, gfx::Font::Weight::MEDIUM);
  if (show_chevron) {
    const int text_w = secondary::TextWidth(label, font);
    const gfx::Rect text_rect(bounds.x() + m::kButtonPaddingX, bounds.y(),
                              text_w, bounds.height());
    secondary::DrawText(canvas, label, font, TextPrimary(), text_rect,
                        gfx::Canvas::TEXT_ALIGN_LEFT);
    const gfx::RectF chevron_box(text_rect.right() + 4.f,
                                 bounds.CenterPoint().y() - 5.f, 10.f, 10.f);
    secondary::PaintGlyph(canvas, secondary::Glyph::kChevronDown, chevron_box,
                          TextSecondary(), 1.4f);
  } else {
    secondary::DrawText(canvas, label, font, TextPrimary(), bounds,
                        gfx::Canvas::TEXT_ALIGN_CENTER);
  }
}

SkColor OpenTranslatePopoverView::TextPrimary() const {
  return appearance_.dark ? secondary::WithAlpha(SK_ColorWHITE, 0.92f)
                          : SkColorSetRGB(0x16, 0x17, 0x1D);
}

SkColor OpenTranslatePopoverView::TextSecondary() const {
  return appearance_.dark ? secondary::WithAlpha(SK_ColorWHITE, 0.62f)
                          : secondary::WithAlpha(SK_ColorBLACK, 0.58f);
}

BEGIN_METADATA(OpenTranslatePopoverView)
END_METADATA

// ===========================================================================
// OpenTranslatePopover
// ===========================================================================

OpenTranslatePopover::OpenTranslatePopover(TranslatePopoverDelegate* delegate)
    : delegate_(delegate) {}

OpenTranslatePopover::~OpenTranslatePopover() {
  DiscardBubble(/*synchronous=*/true);
}

void OpenTranslatePopover::Show(views::View* anchor,
                                const TranslatePopoverState& state,
                                const secondary::Appearance& appearance) {
  ShowInternal(anchor, nullptr, std::nullopt, state, appearance);
}

void OpenTranslatePopover::ShowAtRect(views::Widget* parent_widget,
                                      const gfx::Rect& anchor_rect_in_screen,
                                      const TranslatePopoverState& state,
                                      const secondary::Appearance& appearance) {
  ShowInternal(nullptr, parent_widget, anchor_rect_in_screen, state,
               appearance);
}

void OpenTranslatePopover::ShowInternal(
    views::View* anchor_view,
    views::Widget* parent_widget,
    std::optional<gfx::Rect> anchor_rect_in_screen,
    const TranslatePopoverState& state,
    const secondary::Appearance& appearance) {
  DiscardBubble(/*synchronous=*/false);

  const views::BubbleBorder::Arrow arrow =
      anchor_view ? views::BubbleBorder::TOP_LEFT
                  : views::BubbleBorder::TOP_CENTER;
  bubble_delegate_ = std::make_unique<views::BubbleDialogDelegate>(
      anchor_view, arrow, views::BubbleBorder::DIALOG_SHADOW,
      /*autosize=*/true);
  if (!anchor_view && parent_widget) {
    bubble_delegate_->set_parent_window(parent_widget->GetNativeView());
  }
  if (anchor_rect_in_screen.has_value()) {
    bubble_delegate_->SetAnchorRect(*anchor_rect_in_screen);
  }
  bubble_delegate_->set_margins(gfx::Insets());
  bubble_delegate_->set_fixed_width(
      state.mode == TranslatePopoverMode::kSelection ? m::kSelectionWidth
                                                     : m::kWidth);
  bubble_delegate_->set_corner_radius(m::kCornerRadius);
  bubble_delegate_->SetButtons(
      static_cast<int>(ui::mojom::DialogButton::kNone));
  bubble_delegate_->SetShowCloseButton(false);
  bubble_delegate_->SetShowTitle(false);
  bubble_delegate_->set_close_on_deactivate(true);

  contents_ = bubble_delegate_->SetContentsView(
      std::make_unique<OpenTranslatePopoverView>(delegate_, state, appearance));
  bubble_delegate_->SetBackgroundColor(contents_->panel_color());

  widget_ = views::BubbleDialogDelegate::CreateBubble(
      bubble_delegate_.get(),
      base::BindOnce(&OpenTranslatePopover::OnWidgetClosed,
                     weak_factory_.GetWeakPtr()));
  widget_->Show();
}

void OpenTranslatePopover::UpdateState(const TranslatePopoverState& state) {
  if (contents_) {
    contents_->SetState(state);
    if (bubble_delegate_) {
      bubble_delegate_->SizeToContents();
    }
  }
}

void OpenTranslatePopover::Close() {
  if (widget_) {
    widget_->CloseWithReason(views::Widget::ClosedReason::kUnspecified);
  }
}

bool OpenTranslatePopover::IsShowing() const {
  return widget_ && widget_->IsVisible();
}

void OpenTranslatePopover::OnWidgetClosed(views::Widget::ClosedReason reason) {
  DiscardBubble(/*synchronous=*/false);
  if (delegate_) {
    delegate_->OnTranslatePopoverClosed();
  }
}

void OpenTranslatePopover::DiscardBubble(bool synchronous) {
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
  if (widget_) {
    widget_->Hide();
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(widget_));
  }
  if (bubble_delegate_) {
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(bubble_delegate_));
  }
}

}  // namespace open_unified
