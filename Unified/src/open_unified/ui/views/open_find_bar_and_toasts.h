// Copyright 2026 The Open Authors. All rights reserved.
//
// Three small overlays, each hosted in a `secondary::OverlayWidgetHost`:
//
//   OpenFindBarView   — find in page. docs/re/page-chrome.md §1: 300 × 32,
//                       radius 5, top-right of the page container (10 pt
//                       inset; 50 pt top with the content toolbar), search
//                       icon · query · "1/5" · Previous · Next · Close,
//                       placeholder "Find in page...", "Not Found" in
//                       FindInPageError red. Alignment::kTopRight.
//   OpenToastStackView — non-blocking toasts (ToastMetrics in
//                       Packages/OpenKit/Sources/OpenDesign/PageTokens.swift):
//                       42 pt (46 with a button), radius 11, top-right of the
//                       content panel (8 top, 10 right), up to 4, hover holds
//                       the timer. Alignment::kTopRight.
//   OpenTabSwitcherView — Ctrl+Tab MRU switcher HUD (TabSwitcherTokens.swift,
//                       provisional: no Arc capture). Shows 100 ms after the
//                       first Ctrl+Tab, so a quick tap switches without a
//                       flash; commits on Ctrl release. Alignment::kCenter.
//
// Each view's EmptyBorder is its shadow margin; OverlayWidgetHost aligns the
// inner rect to the anchor.

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_FIND_BAR_AND_TOASTS_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_FIND_BAR_AND_TOASTS_H_

#include <cstddef>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/views/controls/textfield/textfield_controller.h"
#include "ui/views/view.h"

namespace views {
class Textfield;
}  // namespace views

namespace open_unified {

// ===========================================================================
// Find bar.
// ===========================================================================

namespace find_bar_metrics {
inline constexpr int kWidth = 300;
inline constexpr int kHeight = 32;
inline constexpr int kCornerRadius = 5;
inline constexpr int kInset = 10;
inline constexpr int kTopInsetWithToolbar = 50;
inline constexpr int kSearchIconX = 3;
inline constexpr int kSearchIconBox = 26;
inline constexpr int kSearchGlyph = 15;
inline constexpr int kQueryX = 32;
inline constexpr int kQueryTrailingGap = 4;
inline constexpr int kButtonGlyph = 16;
inline constexpr int kButtonInset = 5;
inline constexpr int kCloseTrailing = 3;
inline constexpr int kSeparatorVerticalInset = 7;
// PopoverShadow: blur 5, 3 pt down; margin keeps it inside the widget.
inline constexpr int kShadowMargin = 8;
}  // namespace find_bar_metrics

class FindBarDelegate {
 public:
  virtual ~FindBarDelegate() = default;
  // Every committed text change (Track 6 starts a new find session).
  virtual void OnFindQueryChanged(const std::u16string& query) = 0;
  // Return / Next (forward) and Shift+Return / Previous (backward).
  virtual void OnFindNext(bool forward) = 0;
  // Esc or Close. Track 6 stops finding and hides the overlay widget.
  virtual void OnFindClosed() = 0;
};

class OpenFindBarView : public views::View, public views::TextfieldController {
  METADATA_HEADER(OpenFindBarView, views::View)

 public:
  explicit OpenFindBarView(FindBarDelegate* delegate);
  OpenFindBarView(const OpenFindBarView&) = delete;
  OpenFindBarView& operator=(const OpenFindBarView&) = delete;
  ~OpenFindBarView() override;

  // Shows the bar, optionally seeded (selected text up to 40 characters,
  // newlines replaced by spaces). Invoking Find while the bar shows selects
  // the whole query.
  void Activate(const std::u16string& seed_query);
  void SetResult(int active_ordinal, int total);
  void ClearResult();
  std::u16string_view query() const;
  bool HasCompositionText() const;
  void SetAppearance(const secondary::Appearance& appearance);

  // Anchor for OverlayWidgetHost::SetAnchor(..., kTopRight): the page
  // container inset by 10 (top 50 with the content toolbar).
  static gfx::Rect ComputeAnchor(const gfx::Rect& page_container,
                                 bool has_content_toolbar);
  // The bar's visible bottom edge (shadow margin excluded) for the same
  // inputs, in |page_container|'s coordinates.
  static int ComputeBottom(const gfx::Rect& page_container,
                           bool has_content_toolbar);

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;

  // views::TextfieldController:
  void ContentsChanged(views::Textfield* sender,
                       const std::u16string& new_contents) override;
  bool HandleKeyEvent(views::Textfield* sender,
                      const ui::KeyEvent& key_event) override;

 private:
  enum class ResultType {
    kEmpty,
    kResults,
    kNoResults,
  };

  void Close();
  void UpdateButtons();
  gfx::Rect inner_bounds() const;

  raw_ptr<FindBarDelegate> delegate_;
  raw_ptr<views::Textfield> field_ = nullptr;
  raw_ptr<secondary::GlyphButton> previous_ = nullptr;
  raw_ptr<secondary::GlyphButton> next_ = nullptr;
  raw_ptr<secondary::GlyphButton> close_ = nullptr;
  secondary::Appearance appearance_;
  ResultType result_type_ = ResultType::kEmpty;
  int active_ordinal_ = 0;
  int total_ = 0;
  gfx::Rect count_rect_;
  int separator_x_ = 0;
};

// ===========================================================================
// Toasts.
// ===========================================================================

namespace toast_metrics {
inline constexpr int kHeight = 42;
inline constexpr int kHeightWithButton = 46;
inline constexpr int kTopInset = 8;
inline constexpr int kTrailingInset = 10;
inline constexpr int kCornerRadius = 11;
inline constexpr int kLeadingPadding = 12;
inline constexpr int kTrailingPadding = 12;
inline constexpr int kLabelToButton = 8;
inline constexpr int kButtonTrailing = 10;
inline constexpr int kButtonHeight = 27;
inline constexpr int kButtonRadius = 6;
inline constexpr int kSymbolSize = 14;
inline constexpr int kSymbolToTitle = 6;
inline constexpr int kMinWidth = 60;
inline constexpr int kMaxWidth = 380;
inline constexpr size_t kMaxVisible = 4;
inline constexpr int kStackGap = 8;  // guess: Arc stacks separate windows.
inline constexpr int kFontSize = 14;
inline constexpr int kShadowMargin = 18;
// Measured lifetimes: 3.0 s text-only (PG-1.7), 5.0 s with a button
// (PG-14). The Track 5 brief named 2.5 s; callers can pass that per toast.
inline constexpr base::TimeDelta kLifetime = base::Seconds(3);
inline constexpr base::TimeDelta kLifetimeWithButton = base::Seconds(5);
// The pointer leaving a toast restarts its timer with this much left.
inline constexpr base::TimeDelta kHoverResume = base::Milliseconds(1500);
}  // namespace toast_metrics

struct ToastSpec {
  std::u16string title;
  secondary::Glyph glyph = secondary::Glyph::kNone;
  // Space icon emoji or other leading text (Space Switched); drawn instead of
  // the glyph when set.
  std::u16string leading_text;
  std::u16string button_label;  // e.g. "Undo"; empty: no button.
  base::OnceClosure button_action;
  // Empty: the measured default for the toast's kind.
  std::optional<base::TimeDelta> lifetime;

  // Arc's copy toast text (PG-1.2).
  static ToastSpec CopiedUrl();
  static ToastSpec TabArchived(base::OnceClosure undo);
  static ToastSpec SpaceSwitched(const std::u16string& space_title,
                                 const std::u16string& icon_text);
};

namespace toast_internal {
class ToastView;
}  // namespace toast_internal

class OpenToastStackView : public views::View {
  METADATA_HEADER(OpenToastStackView, views::View)

 public:
  OpenToastStackView();
  OpenToastStackView(const OpenToastStackView&) = delete;
  OpenToastStackView& operator=(const OpenToastStackView&) = delete;
  ~OpenToastStackView() override;

  // Shows a toast at the top; older ones move down; the fifth drops.
  void Show(ToastSpec spec);
  void DismissAll();
  size_t toast_count() const { return toasts_.size(); }
  void SetAppearance(const secondary::Appearance& appearance);
  // Runs with true when the first toast appears and false when the last one
  // goes, so Track 6 can show or hide the overlay widget.
  void SetVisibilityCallback(base::RepeatingCallback<void(bool)> callback);

  // Anchor for OverlayWidgetHost::SetAnchor(..., kTopRight). The Find bar
  // shares the panel's top-right corner: while it shows, pass its bottom
  // edge (OpenFindBarView::ComputeBottom(), same coordinates) and the stack
  // starts kStackGap below it; with nullopt the stack uses its own top
  // inset again.
  static gfx::Rect ComputeAnchor(const gfx::Rect& content_panel,
                                 std::optional<int> find_bar_bottom);

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;

 private:
  friend class toast_internal::ToastView;

  // Removes `toast` on the next task (it may be inside its own timer or
  // button callback).
  void ScheduleRemove(toast_internal::ToastView* toast);
  void Remove(toast_internal::ToastView* toast);

  std::vector<raw_ptr<toast_internal::ToastView>> toasts_;
  secondary::Appearance appearance_;
  base::RepeatingCallback<void(bool)> visibility_callback_;
  base::WeakPtrFactory<OpenToastStackView> weak_factory_{this};
};

// ===========================================================================
// Ctrl+Tab switcher.
// ===========================================================================

namespace tab_switcher_metrics {
inline constexpr int kItemWidth = 180;
inline constexpr int kItemHeight = 140;
inline constexpr int kGap = 8;
inline constexpr int kInset = 16;
inline constexpr int kHeadingHeight = 28;
inline constexpr int kCornerRadius = 16;
inline constexpr size_t kMaximumVisible = 5;
// ArcMain 0x1024b69e8: one-shot presentation at request time + 0.1 s.
inline constexpr base::TimeDelta kPresentationDelay = base::Milliseconds(100);
inline constexpr int kShadowMargin = 24;
}  // namespace tab_switcher_metrics

struct TabSwitcherItem {
  ItemID tab_id;
  std::u16string title;
  std::u16string host;
  gfx::ImageSkia favicon;
  gfx::ImageSkia thumbnail;  // Optional page snapshot.
};

class TabSwitcherDelegate {
 public:
  virtual ~TabSwitcherDelegate() = default;
  // The HUD should appear (after the 100 ms delay) or go: show or hide the
  // overlay widget. Focus moves to the HUD so it sees the Ctrl release.
  virtual void OnTabSwitcherVisibilityChanged(bool visible) = 0;
  // Live preview highlight moved (optional: Track 6 may preview the tab).
  virtual void OnTabSwitcherHighlight(const ItemID& tab_id) {}
  // Ctrl released, Return, or a click: switch to this tab.
  virtual void OnTabSwitcherCommit(const ItemID& tab_id) = 0;
  // Esc: stay on the current tab.
  virtual void OnTabSwitcherCancel() = 0;
};

class OpenTabSwitcherView : public views::View {
  METADATA_HEADER(OpenTabSwitcherView, views::View)

 public:
  explicit OpenTabSwitcherView(TabSwitcherDelegate* delegate);
  OpenTabSwitcherView(const OpenTabSwitcherView&) = delete;
  OpenTabSwitcherView& operator=(const OpenTabSwitcherView&) = delete;
  ~OpenTabSwitcherView() override;

  // First Ctrl+Tab (or Ctrl+Shift+Tab with `reverse`). `items` is MRU order
  // with the current tab first; the highlight starts on the previous tab.
  void Begin(std::vector<TabSwitcherItem> items, bool reverse);
  // Further Tab presses while Ctrl is held.
  void Advance(bool reverse);
  // Ctrl released: commit the highlighted tab (also before the HUD shows).
  void Commit();
  void Cancel();
  bool is_active() const { return active_; }
  bool is_shown() const { return shown_; }
  void SetAppearance(const secondary::Appearance& appearance);

  // Routes keys while active (Track 6 forwards from its key router before
  // the HUD has focus). Returns true when consumed.
  bool HandleKeyEvent(const ui::KeyEvent& event);

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void OnPaint(gfx::Canvas* canvas) override;
  bool OnKeyPressed(const ui::KeyEvent& event) override;
  bool OnKeyReleased(const ui::KeyEvent& event) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  void OnMouseMoved(const ui::MouseEvent& event) override;

 private:
  void Present();
  void Finish();
  void SetHighlight(size_t index);
  size_t first_visible() const;
  gfx::Rect ItemRect(size_t visible_index) const;
  gfx::Rect inner_bounds() const;

  raw_ptr<TabSwitcherDelegate> delegate_;
  std::vector<TabSwitcherItem> items_;
  size_t highlight_ = 0;
  bool active_ = false;
  bool shown_ = false;
  secondary::Appearance appearance_;
  base::OneShotTimer present_timer_;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_FIND_BAR_AND_TOASTS_H_
