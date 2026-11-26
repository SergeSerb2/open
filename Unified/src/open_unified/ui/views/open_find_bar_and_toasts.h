// Copyright 2026 The Open Authors. All rights reserved.
//
// Three small overlays, each hosted in a `secondary::OverlayWidgetHost`:
//
//   OpenFindBarView   — find in page. docs/re/page-chrome.md §1: 300 × 32,
//                       radius 5, top-right of the page container (10 pt
//                       inset; 50 pt top with the content toolbar), search
//                       icon · query · "1/5" · Previous · Next · Close,
//                       placeholder "Find in page...", "Not Found" in
//                       FindInPageError red. Alignment::kTopRight. It can
//                       target any page (Peek, the focused Split pane, the
//                       active tab) and then runs find itself.
//   OpenToastStackView — non-blocking toasts (ToastMetrics in
//                       Packages/OpenKit/Sources/OpenDesign/PageTokens.swift):
//                       42 pt (46 with a button, 60 with a subtitle), radius
//                       11, top-right of the content panel (8 top, 10 right),
//                       up to 4, hover holds the timer, spring in / shrink
//                       out (Motion.toastIn / toastOut). One OpenToastKind
//                       per message Open shows. Alignment::kTopRight.
//   OpenTabSwitcherView — Ctrl+Tab MRU switcher HUD (TabSwitcherTokens.swift,
//                       provisional: no Arc capture). Shows 100 ms after the
//                       first Ctrl+Tab, so a quick tap switches without a
//                       flash; commits on Ctrl release. Cards carry live page
//                       thumbnails fed through UpdateThumbnail().
//                       Alignment::kCenter.
//
// Each view's EmptyBorder is its shadow margin; OverlayWidgetHost aligns the
// inner rect to the anchor.

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_FIND_BAR_AND_TOASTS_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_FIND_BAR_AND_TOASTS_H_

#include <cstddef>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "components/find_in_page/find_result_observer.h"
#include "components/find_in_page/find_tab_helper.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/views/controls/textfield/textfield_controller.h"
#include "ui/views/view.h"

namespace content {
class WebContents;
}  // namespace content

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
  // The page set with OpenFindBarView::SetTarget() went away (Peek closed,
  // tab destroyed). Default: treat it like Close.
  virtual void OnFindTargetDestroyed() { OnFindClosed(); }
};

class OpenFindBarView : public views::View,
                        public views::TextfieldController,
                        public find_in_page::FindResultObserver {
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

  // Targets `contents`: Peek's page while Peek shows, the focused Split pane
  // while Split View shows, else the active tab. With a target, the bar runs
  // find itself through the page's find_in_page::FindTabHelper (query, Return
  // / Shift+Return, the "3/14" count, Esc), and the delegate gets only
  // OnFindClosed() and OnFindTargetDestroyed(). A new target stops the old
  // page's session (its highlights clear) and searches the new page with the
  // current query. nullptr (the default) keeps the delegate-driven mode.
  void SetTarget(content::WebContents* contents);
  content::WebContents* target() const { return target_; }
  // Case-sensitive matching (re-runs the search). The "Aa" toggle shows only
  // with SetShowsCaseToggle(true): Arc's bar has none.
  void SetCaseSensitive(bool case_sensitive);
  bool case_sensitive() const { return case_sensitive_; }
  void SetShowsCaseToggle(bool shows);
  // Ends the target's session and clears its match highlights (Esc and
  // Close do this before OnFindClosed()).
  void StopFinding();
  int active_ordinal() const { return active_ordinal_; }
  int total() const { return total_; }

  // find_in_page::FindResultObserver:
  void OnFindResultAvailable(content::WebContents* web_contents) override;
  void OnFindTabHelperDestroyed(find_in_page::FindTabHelper* helper) override;

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
  find_in_page::FindTabHelper* target_helper() const;
  void FindInTarget(bool forward);
  void PaintCaseToggle(gfx::Canvas* canvas,
                       const gfx::Rect& bounds,
                       bool hovered);

  raw_ptr<FindBarDelegate> delegate_;
  raw_ptr<content::WebContents> target_ = nullptr;
  base::ScopedObservation<find_in_page::FindTabHelper,
                          find_in_page::FindResultObserver>
      find_observation_{this};
  bool case_sensitive_ = false;
  bool shows_case_toggle_ = false;
  raw_ptr<secondary::PaintedButton> case_toggle_ = nullptr;
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
// Title plus subtitle (14 pt + 12 pt), guess (ToastMetrics.heightTwoLine).
inline constexpr int kHeightTwoLine = 60;
inline constexpr int kSubtitleFontSize = 12;
inline constexpr int kLineGap = 2;
// Icon button (Undo, Share): 32 × 27, 10 below the top (PG-1.3).
inline constexpr int kIconButtonWidth = 32;
inline constexpr int kButtonTop = 10;
inline constexpr int kButtonSymbolSize = 13;
// Keycap plates before the title: 27 tall, radius 6, ink + 18, fill 0.10 of
// the text color, 4 apart, 6 to the title (the hint toast's plate).
inline constexpr int kKeycapHeight = 27;
inline constexpr int kKeycapRadius = 6;
inline constexpr int kKeycapInkPadding = 18;
inline constexpr float kKeycapAlpha = 0.10f;
inline constexpr int kKeycapGap = 4;
inline constexpr int kKeycapToTitle = 6;
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
// Undo toasts last as long as their source can undo (sidebar undo 5 s,
// Peek's undo window 5 s).
inline constexpr base::TimeDelta kUndoLifetime = base::Seconds(5);
}  // namespace toast_metrics

// Every message Open shows as a toast. Titles marked (macOS) are the Swift
// app's own strings; the others are Open's wording for the same event.
enum class OpenToastKind {
  kCustom,  // Title and accessory from the spec only.
  // Copy.
  kCopiedUrl,         // "Copied Current URL" (PG-1.2)
  kCopiedCleanLink,   // "Copied a clean link without trackers" (macOS)
  kCopiedCleanLinks,  // "Copied clean links without trackers" (macOS)
  kCopiedMarkdown,    // "Copied URL as Markdown"
  kCopiedQuoteLink,   // "Copied Quote Link" (macOS)
  kCopied,            // "Copied" (macOS)
  kCopiedImage,       // "Copied Image" (macOS)
  kCopiedEaselUrl,    // "Copied Easel URL" (macOS)
  kCopiedOpenInfo,    // "Copied Open Info" (macOS)
  // Tabs and windows.
  kTabArchived,           // "Tab Archived" + Undo
  kClosedWindow,          // "Window Closed" + Undo
  kTabRestored,           // "Tab Restored"
  kTabReset,              // "Tab Reset"
  kTabPinned,             // "Tab Pinned"
  kTabUnpinned,           // "Tab Unpinned"
  kAddedToFavorites,      // "Added to Favorites"
  kRemovedFromFavorites,  // "Removed from Favorites"
  kClearedTabs,           // "Cleared Tabs" + Undo (macOS)
  kArchiveCleared,        // "Archive Cleared"
  kFolderDeleted,         // "Folder deleted" + Undo (macOS)
  kTabsNotSaved,          // "Your tabs could not be saved" (macOS)
  kSplitViewAdded,        // "Added to Split View"
  kSplitViewClosed,       // "Split View Closed" + Undo
  // Spaces and Profiles.
  kSpaceSwitched,    // The Space's name with its icon.
  kSpaceCreated,     // "Space Created"
  kSpaceDeleted,     // "Space Deleted" + Undo
  kProfileSwitched,  // "Switched to <Profile>"
  // Peek and Little Open.
  kPeekClosed,        // "Peek closed" + Undo (macOS)
  kPeekPromoted,      // "Opened as Tab"
  kSentToLittleOpen,  // "Opened in Little Open"
  // Extensions.
  kExtensionInstalled,   // "Added <name>" (macOS)
  kExtensionLoadFailed,  // "Couldn't load extension" + error (macOS)
  kExtensionPinned,      // "Pinned <name>"
  kExtensionUnpinned,    // "Unpinned <name>"
  // Boosts and Zap.
  kBoostApplied,   // "Boost Applied"
  kBoostDisabled,  // "Boost Turned Off"
  kBoostFailed,    // "Could not apply Boosts." (macOS)
  kZapSaved,       // "Zapped" + Undo
  // Ad blocking and site data.
  kAdBlockEnabled,       // "Ad Blocking On"
  kAdBlockPaused,        // "Ad Blocking Paused" (+ host)
  kAdBlockSaveFailed,    // "Ad blocking settings could not be saved." (macOS)
  kSiteDataClearFailed,  // "Site data could not be cleared." (macOS)
  // Downloads.
  kDownloadStarted,    // "Downloading <file>" + Show
  kDownloadCompleted,  // "Downloaded <file>" + Show
  kDownloadFailed,     // "Download Failed" (+ file)
  // Capture.
  kCaptureInProgress,  // "Capture in Progress", sticky (macOS)
  kCaptureSaved,       // "Capture Saved" + Open
  kCaptureHint,  // [⌘][⇧] "and drag your mouse to capture any time." (macOS)
  // Page.
  kPageTranslated,    // "Translated to <language>"
  kZoom,              // "<n>%" (coalesced "zoom")
  kDeveloperModeOn,   // "Developer Mode On" (macOS)
  kDeveloperModeOff,  // "Developer Mode Off" (macOS)
  // Documents.
  kEaselSaved,  // "Easel Saved" (macOS)
  kNoteSaved,   // "Note Saved" (macOS)
  // Sync.
  kSyncCompleted,  // "Synced"
  kSyncConflict,   // "Sync Conflict" + Show
  kSyncFailed,     // "Sync Failed" (+ reason)
  // Generic.
  kInfo,
  kWarning,
  kError,
};

// Stable lowercase name for automation ("copied-url", "tab-archived", ...).
std::string_view OpenToastKindName(OpenToastKind kind);

// What one toast shows (ToastContent in ToastCenter.swift):
// [symbol or leading text][keycaps][title / subtitle][button].
struct ToastSpec {
  ToastSpec();
  ToastSpec(ToastSpec&&);
  ToastSpec& operator=(ToastSpec&&);
  ~ToastSpec();

  OpenToastKind kind = OpenToastKind::kCustom;
  std::u16string title;
  std::u16string subtitle;
  secondary::Glyph glyph = secondary::Glyph::kNone;
  // macOS SF Symbol for the leading icon; drawn instead of `glyph` where the
  // platform has system symbols ("link", "checkmark", ...).
  std::string symbol_name;
  // Space icon emoji or other leading text (Space Switched); drawn instead of
  // the glyph when set.
  std::u16string leading_text;
  // "⌘", "⇧" plates before the title (the capture hint).
  std::vector<std::u16string> keycaps;
  std::u16string button_label;  // e.g. "Show"; empty: no text button.
  // An icon button (32 × 27, PG-1.3) instead of a text button: Undo
  // (arrow.uturn.backward), Share. `button_label` is its accessible name.
  secondary::Glyph button_glyph = secondary::Glyph::kNone;
  std::string button_symbol_name;
  base::OnceClosure button_action;
  // Empty: the measured default for the toast's kind (3 s; 5 s with a
  // button; Undo 5 s).
  std::optional<base::TimeDelta> lifetime;
  // Stays until dismissed or updated (Capture in Progress, exports).
  bool sticky = false;
  // Names the family ("zoom") for automation; same-key toasts still make a
  // new toast (PG-1.8).
  std::string coalescing_key;

  bool has_button() const {
    return !button_label.empty() || button_glyph != secondary::Glyph::kNone;
  }
  bool has_icon_button() const {
    return button_glyph != secondary::Glyph::kNone;
  }

  // The standard toast for `kind`. `detail` fills names (extension, file,
  // Space, Profile, language, zoom percent) or replaces the title for the
  // generic kinds; `action` runs on the button (Undo, Show, Open).
  static ToastSpec ForKind(OpenToastKind kind,
                           std::u16string detail = {},
                           base::OnceClosure action = {});
  static ToastSpec Undo(std::u16string title, base::OnceClosure undo);
  static ToastSpec Info(std::u16string title, std::u16string subtitle = {});
  static ToastSpec Warning(std::u16string title, std::u16string subtitle = {});
  static ToastSpec Error(std::u16string title, std::u16string subtitle = {});

  // Arc's copy toast text (PG-1.2).
  static ToastSpec CopiedUrl();
  static ToastSpec TabArchived(base::OnceClosure undo);
  static ToastSpec SpaceSwitched(const std::u16string& space_title,
                                 const std::u16string& icon_text);
};
using OpenToastSpec = ToastSpec;

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
  // Returns the toast's id (for Update / Dismiss).
  int Show(ToastSpec spec);
  int ShowToast(OpenToastSpec spec) { return Show(std::move(spec)); }
  int ShowKind(OpenToastKind kind,
               std::u16string detail = {},
               base::OnceClosure action = {});
  // Thin helpers over ShowToast().
  int ShowCopiedUrl();
  int ShowUndo(std::u16string title, base::OnceClosure undo);
  int ShowTabArchived(base::OnceClosure undo);
  int ShowSpaceSwitched(const std::u16string& space_title,
                        const std::u16string& icon_text);
  // Same toast, new content (a sticky "Capture in Progress" becomes "Copied
  // Image"). The deadline restarts when stickiness changes.
  void Update(int toast_id, ToastSpec spec);
  void Dismiss(int toast_id);
  void DismissKind(OpenToastKind kind);
  void DismissAll();
  // Clicks the button of the visible toast at `index` (newest first).
  bool PerformAction(size_t index);
  bool IsShowing(int toast_id) const;
  // Arc (PG-1.8): a new toast makes every older one leave at once. Off (the
  // default) keeps up to 4 stacked.
  void SetReplacesOlderToasts(bool replaces) { replaces_older_ = replaces; }
  size_t toast_count() const { return toasts_.size(); }
  const std::u16string& last_title() const { return last_title_; }
  OpenToastKind last_kind() const { return last_kind_; }
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
  toast_internal::ToastView* FindToast(int toast_id) const;

  std::vector<raw_ptr<toast_internal::ToastView>> toasts_;
  secondary::Appearance appearance_;
  int next_toast_id_ = 1;
  bool replaces_older_ = false;
  std::u16string last_title_;
  OpenToastKind last_kind_ = OpenToastKind::kCustom;
  base::RepeatingCallback<void(bool)> visibility_callback_;
  base::WeakPtrFactory<OpenToastStackView> weak_factory_{this};
};

// ===========================================================================
// Ctrl+Tab switcher.
// ===========================================================================

namespace tab_switcher_metrics {
inline constexpr int kItemWidth = 180;
// A card is 180 × 124 (rounded 10, accent ring when highlighted) with the
// page thumbnail inset 6; the favicon, title and host / Space line sit in a
// 40 pt label under it.
inline constexpr int kCardHeight = 124;
inline constexpr int kCardRadius = 10;
inline constexpr int kThumbnailInset = 6;
inline constexpr int kThumbnailRadius = 6;
inline constexpr int kLabelHeight = 40;
inline constexpr int kItemHeight = kCardHeight + kLabelHeight;
// Captures are requested at 16:10 (the usual page aspect) and drawn
// aspect-fill, top aligned, into the 168 × 112 thumbnail frame.
inline constexpr int kThumbnailAspectWidth = 16;
inline constexpr int kThumbnailAspectHeight = 10;
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
  TabSwitcherItem();
  TabSwitcherItem(const TabSwitcherItem&);
  TabSwitcherItem(TabSwitcherItem&&) noexcept;
  TabSwitcherItem& operator=(const TabSwitcherItem&);
  TabSwitcherItem& operator=(TabSwitcherItem&&) noexcept;
  ~TabSwitcherItem();

  ItemID tab_id;
  std::u16string title;
  std::u16string host;
  gfx::ImageSkia favicon;
  gfx::ImageSkia thumbnail;  // Optional page snapshot.
  // Second label line: "host · Space"; empty: `host`.
  std::u16string subtitle;
  // No live page (discarded): the card shows a "Sleeping" placeholder and
  // never asks for a thumbnail.
  bool is_sleeping = false;
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
  // Cards without a thumbnail came into view: capture these live pages
  // (RenderWidgetHostView::CopyFromSurface, never loading a sleeping tab)
  // and answer with UpdateThumbnail(). Each id is asked once per session.
  virtual void OnTabSwitcherNeedsThumbnails(
      const std::vector<ItemID>& tab_ids) {}
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

  // A late page snapshot (or a fresher favicon) for a card while the
  // switcher is open. Ignored for tabs not in this session.
  void UpdateThumbnail(const ItemID& tab_id, const gfx::ImageSkia& thumbnail);
  void UpdateFavicon(const ItemID& tab_id, const gfx::ImageSkia& favicon);
  // Thumbnail size to capture, in DIPs (16:10, the card's frame width).
  static gfx::Size ThumbnailSize();
  // Cards on screen now, in order.
  std::vector<ItemID> visible_tab_ids() const;

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
  // Asks the delegate for thumbnails of visible cards that have none.
  void RequestVisibleThumbnails();
  void PaintCard(gfx::Canvas* canvas,
                 const TabSwitcherItem& item,
                 const gfx::Rect& item_rect,
                 bool selected);

  raw_ptr<TabSwitcherDelegate> delegate_;
  std::vector<TabSwitcherItem> items_;
  size_t highlight_ = 0;
  bool active_ = false;
  bool shown_ = false;
  secondary::Appearance appearance_;
  base::OneShotTimer present_timer_;
  std::vector<ItemID> thumbnails_requested_;
  base::WeakPtrFactory<OpenTabSwitcherView> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_FIND_BAR_AND_TOASTS_H_
