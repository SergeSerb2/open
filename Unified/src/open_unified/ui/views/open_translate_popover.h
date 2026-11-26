// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// OpenTranslatePopover: native anchored Views popover for Page Translation
// and Selection Translation (1:1 parity with TranslatePopoverView.swift and
// TranslateSelection.swift).
//
// Construction note: Chromium 156 restricts views::BubbleDialogDelegateView
// constructors, so OpenTranslatePopover uses views::BubbleDialogDelegate with
// an owned OpenTranslatePopoverView contents view (same pattern as
// OpenSiteControlBubble).

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_TRANSLATE_POPOVER_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_TRANSLATE_POPOVER_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/menus/simple_menu_model.h"
#include "ui/views/view.h"
#include "ui/views/widget/widget.h"

namespace ui {
class SimpleComboboxModel;
}  // namespace ui

namespace views {
class BubbleDialogDelegate;
class Checkbox;
class Combobox;
class Label;
class MenuRunner;
class ScrollView;
}  // namespace views

namespace open_unified {

namespace translate_metrics {
inline constexpr int kWidth = 316;
inline constexpr int kSelectionWidth = 328;
inline constexpr int kPadding = 16;
inline constexpr int kCornerRadius = 12;
inline constexpr int kRowGap = 10;
inline constexpr int kSmallGap = 6;
inline constexpr int kDropdownHeight = 28;
inline constexpr int kArrowWidth = 22;
inline constexpr int kButtonHeight = 28;
inline constexpr float kButtonRadius = 7.f;
inline constexpr int kButtonGap = 8;
inline constexpr int kButtonPaddingX = 14;
inline constexpr int kTitleFontSize = 13;
inline constexpr int kBodyFontSize = 13;
inline constexpr int kMetaFontSize = 11;
inline constexpr int kErrorFontSize = 12;
inline constexpr int kSelectionMaxHeight = 180;
}  // namespace translate_metrics

struct TranslateLanguageOption {
  std::string code;
  std::u16string name;

  bool operator==(const TranslateLanguageOption&) const = default;
};

enum class TranslatePopoverMode {
  kOffer,
  kTranslating,
  kTranslated,
  kSelection,
};

struct TranslatePopoverState {
  TranslatePopoverState();
  TranslatePopoverState(const TranslatePopoverState&);
  TranslatePopoverState(TranslatePopoverState&&) noexcept;
  TranslatePopoverState& operator=(const TranslatePopoverState&);
  TranslatePopoverState& operator=(TranslatePopoverState&&) noexcept;
  ~TranslatePopoverState();

  TranslatePopoverMode mode = TranslatePopoverMode::kOffer;
  std::string source_lang = "auto";
  std::string target_lang = "en";
  std::string host;
  std::u16string title;
  std::u16string error;
  bool always_translate_source = false;
  bool never_translate_host = false;
  std::vector<TranslateLanguageOption> source_languages;
  std::vector<TranslateLanguageOption> target_languages;

  // Compact selection translation panel fields (mode == kSelection).
  std::u16string selected_text;
  std::u16string translated_selection;
  bool selection_loading = false;
};

class TranslatePopoverDelegate {
 public:
  virtual ~TranslatePopoverDelegate() = default;

  virtual void OnTranslateRequested(const std::string& source_lang,
                                    const std::string& target_lang) = 0;
  virtual void OnShowOriginalRequested() = 0;
  virtual void OnAlwaysTranslateToggled(const std::string& source_lang,
                                        const std::string& target_lang,
                                        bool always) = 0;
  virtual void OnNeverTranslateHostToggled(const std::string& host,
                                           bool never) = 0;
  virtual void OnSelectionTargetLanguageChanged(
      const std::string& target_lang) {}
  virtual void OnCopyTranslatedSelection(const std::u16string& text) {}
  virtual void OnOpenLanguageSettings() {}
  virtual void OnTranslatePopoverClosed() {}
};

// Canonical top-25 languages for dropdowns (plus Auto-detect for source).
std::vector<TranslateLanguageOption> DefaultTranslateTargetLanguages();
std::vector<TranslateLanguageOption> DefaultTranslateSourceLanguages();
std::u16string TranslateLanguageDisplayName(const std::string& code);

class OpenTranslatePopoverView : public views::View,
                                 public ui::SimpleMenuModel::Delegate {
  METADATA_HEADER(OpenTranslatePopoverView, views::View)

 public:
  OpenTranslatePopoverView(TranslatePopoverDelegate* delegate,
                           const TranslatePopoverState& state,
                           const secondary::Appearance& appearance);
  OpenTranslatePopoverView(const OpenTranslatePopoverView&) = delete;
  OpenTranslatePopoverView& operator=(const OpenTranslatePopoverView&) = delete;
  ~OpenTranslatePopoverView() override;

  void SetState(const TranslatePopoverState& state);
  const TranslatePopoverState& state() const { return state_; }
  SkColor panel_color() const;

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;

  // ui::SimpleMenuModel::Delegate:
  void ExecuteCommand(int command_id, int event_flags) override;
  bool IsCommandIdChecked(int command_id) const override;
  bool IsCommandIdEnabled(int command_id) const override;

 private:
  void Rebuild();
  void PopulateLanguageListsIfEmpty();
  std::string SelectedSourceCode() const;
  std::string SelectedTargetCode() const;
  void OnSourceLanguageChanged();
  void OnTargetLanguageChanged();
  void OnPrimaryButtonPressed();
  void OnSecondaryButtonPressed();
  void OnOptionsButtonPressed();
  void OnAlwaysTranslateCheckboxPressed();
  void OnNeverTranslateCheckboxPressed();
  void ShowOptionsMenu();

  void PaintPrimaryButton(gfx::Canvas* canvas,
                          const gfx::Rect& bounds,
                          bool hovered);
  void PaintSecondaryButton(std::u16string label,
                            bool show_chevron,
                            gfx::Canvas* canvas,
                            const gfx::Rect& bounds,
                            bool hovered);

  SkColor TextPrimary() const;
  SkColor TextSecondary() const;

  raw_ptr<TranslatePopoverDelegate> delegate_;
  TranslatePopoverState state_;
  secondary::Appearance appearance_;

  raw_ptr<views::Label> title_label_ = nullptr;
  raw_ptr<views::Label> error_label_ = nullptr;
  raw_ptr<views::Combobox> source_combobox_ = nullptr;
  raw_ptr<views::Label> arrow_label_ = nullptr;
  raw_ptr<views::Combobox> target_combobox_ = nullptr;
  raw_ptr<views::Checkbox> always_translate_checkbox_ = nullptr;
  raw_ptr<views::Checkbox> never_translate_checkbox_ = nullptr;
  raw_ptr<views::ScrollView> selection_scroll_ = nullptr;
  raw_ptr<views::Label> selection_result_label_ = nullptr;
  raw_ptr<secondary::PaintedButton> primary_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> secondary_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> options_button_ = nullptr;

  std::unique_ptr<ui::SimpleComboboxModel> source_model_;
  std::unique_ptr<ui::SimpleComboboxModel> target_model_;
  std::unique_ptr<ui::SimpleMenuModel> options_menu_model_;
  std::unique_ptr<views::MenuRunner> options_menu_runner_;
};

// Owns the bubble widget and delegate for one browser window.
class OpenTranslatePopover {
 public:
  explicit OpenTranslatePopover(TranslatePopoverDelegate* delegate);
  OpenTranslatePopover(const OpenTranslatePopover&) = delete;
  OpenTranslatePopover& operator=(const OpenTranslatePopover&) = delete;
  ~OpenTranslatePopover();

  // Opens anchored to a sidebar/toolbar view (e.g. URL pill or status chip).
  void Show(views::View* anchor,
            const TranslatePopoverState& state,
            const secondary::Appearance& appearance);

  // Opens anchored to a screen rectangle (e.g. text selection or context menu).
  void ShowAtRect(views::Widget* parent_widget,
                  const gfx::Rect& anchor_rect_in_screen,
                  const TranslatePopoverState& state,
                  const secondary::Appearance& appearance);

  void UpdateState(const TranslatePopoverState& state);
  void Close();
  bool IsShowing() const;

  OpenTranslatePopoverView* contents() { return contents_; }
  views::Widget* widget() { return widget_.get(); }

 private:
  void ShowInternal(views::View* anchor_view,
                    views::Widget* parent_widget,
                    std::optional<gfx::Rect> anchor_rect_in_screen,
                    const TranslatePopoverState& state,
                    const secondary::Appearance& appearance);
  void OnWidgetClosed(views::Widget::ClosedReason reason);
  void DiscardBubble(bool synchronous);

  raw_ptr<TranslatePopoverDelegate> delegate_;
  std::unique_ptr<views::BubbleDialogDelegate> bubble_delegate_;
  std::unique_ptr<views::Widget> widget_;
  raw_ptr<OpenTranslatePopoverView> contents_ = nullptr;
  base::WeakPtrFactory<OpenTranslatePopover> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_TRANSLATE_POPOVER_H_
