// Copyright 2026 The Open Authors. All rights reserved.
//
// OpenCommandBarView: the zero-animation command bar (Cmd/Ctrl+T, Cmd/Ctrl+L,
// Actions and Tabs scopes, Little Open's embedded bar).
//
// Sources: docs/commandbar.md (§3 measured spec, §4 behavior, §4.1 inline
// completion, §5 no motion, §12 D3 card) and
// Packages/OpenKit/Sources/OpenDesign/CommandBarTokens.swift
// (`CommandBarMetrics`, `CommandCardLayout`, `CommandCard`).
//
// Hosting: the view fills an overlay that covers the browser window's client
// area (scrim, outside clicks). Track 6 hosts it in a
// `secondary::OverlayWidgetHost` with Alignment::kFill and shows that widget
// before `Present()`; on `OnCommandBarDismissed` it hides the widget. Present
// and dismiss change one frame: no scale, no fade (commandbar.md §5).
// In Little Open, the view instead fills the Little Open window's bar slot
// (mode kLittleOpen: the card is the whole view, 490 × 329).

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_COMMAND_BAR_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_COMMAND_BAR_VIEW_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/core/suggest/suggest_engine.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/range/range.h"
#include "ui/views/controls/textfield/textfield_controller.h"
#include "ui/views/view.h"
#include "url/gurl.h"

namespace views {
class Textfield;
}  // namespace views

namespace open_unified {

// CommandBarMetrics / CommandCard / CommandCardLayout values.
namespace command_bar_metrics {
// Panel width 766 (docs/commandbar.md §3.1, F0049/F0063; the D3 card's 768
// includes its hairline).
inline constexpr int kPanelWidth = 766;
inline constexpr int kCornerRadius = 12;
inline constexpr int kMaxVisibleRows = 5;
inline constexpr int kMaxRows = 12;
// Panel with no rows: the input row only.
inline constexpr int kEmptyHeight = 64;
// top = (H - 339) / 2, the same for any row count.
inline constexpr int kCenteringHeight = 339;
inline constexpr int kMinimumWindowMargin = 40;
inline constexpr int kMinimumPanelWidth = 320;
// Inline editor anchored to the sidebar URL pill: 1 pt above it, at least
// 340 wide.
inline constexpr int kInlineMinimumWidth = 340;
inline constexpr int kInlineTopOffset = -1;
// Little Open's embedded bar: 490 wide, 79 + 5 × 50 = 329; close button
// [W - 47, 19, 26, 26].
inline constexpr int kLittleOpenWidth = 490;
inline constexpr int kLittleOpenCloseSize = 26;
inline constexpr int kLittleOpenCloseTrailing = 47;
inline constexpr int kLittleOpenCloseY = 19;
// Scope chip: Display P3 #FFA500 capsule, 24 tall, radius 12, text + 2 × 10,
// field starts 13 pt after it; glow blur 16 at 0.32 alpha.
inline constexpr SkColor kScopeChipColor = SkColorSetRGB(0xFF, 0xA5, 0x00);
inline constexpr int kChipHeight = 24;
inline constexpr int kChipPaddingX = 10;
inline constexpr int kChipToText = 13;
// Input caps pasted or typed text at 2,048 characters.
inline constexpr size_t kMaxInputLength = 2048;
// (i) button [W − 47, 19, 26, 26] drawing a 24 pt circle (F0063).
inline constexpr int kInfoButtonSize = 26;
inline constexpr int kInfoCircleDiameter = 24;
// Privacy footer (CC-42, S2 18/0044): a black band [0, H − 61, W, 61];
// panels with fewer than 2 rows grow by it. Buttons "Search Settings…"
// [W − 223.5, H − 49.5, 132, 37] and "Dismiss" [W − 82.5, H − 49.5, 72, 37].
inline constexpr int kFooterHeight = 61;
inline constexpr size_t kFooterGrowthRowLimit = 2;
inline constexpr int kFooterTextX = 46;
inline constexpr int kFooterLine1Top = 13;
inline constexpr int kFooterLine2Top = 31;
inline constexpr int kFooterIconX = 18;
inline constexpr int kFooterIconY = 24;
inline constexpr int kFooterIconSize = 13;
inline constexpr int kFooterButtonTop = 12;  // 61 − 49.5, on the pixel grid.
inline constexpr int kFooterButtonHeight = 37;
inline constexpr int kFooterSettingsButtonWidth = 132;
inline constexpr int kFooterDismissButtonWidth = 72;
inline constexpr int kFooterDismissTrailing = 10;
inline constexpr int kFooterButtonGap = 9;
inline constexpr int kFooterButtonRadius = 8;
}  // namespace command_bar_metrics

enum class CommandBarMode {
  kNewTab,          // Cmd/Ctrl+T: empty field, opens new Today tabs.
  kEditCurrentUrl,  // Cmd/Ctrl+L: current URL selected, navigates in place.
  kSearchActions,   // Opens in the Actions scope.
  kSearchTabs,      // Opens in the Tabs scope.
  kLittleOpen,      // Little Open's embedded bar.
};

enum class CommandBarScope {
  kNone,
  kSiteSearch,
  kActions,
  kTabs,
};

enum class CommandBarRowKind {
  kNavigate,
  kHistory,
  kSwitchToTab,
  kSwitchToSplit,
  kSearch,
  kSearchSuggestion,
  kAction,
  kCalculator,
  kSiteSearch,
  kCurrentPage,
};

enum class CommandBarDisposition {
  kCurrentTab,
  kNewForegroundTab,
  kNewBackgroundTab,  // Cmd/Ctrl+Return: the bar stays open.
  kSplitView,         // Alt/Option+Return.
};

enum class CommandBarDismissReason {
  kEscape,
  kClickOutside,
  kCommitted,
  kCloseButton,  // Little Open's close button.
  kProgrammatic,
};

// One suggestion row, produced by Track 2's SuggestEngine through the
// delegate. The bar never ranks: it shows rows in the order given.
// Why a row exists beyond its kind (kinds stay fixed: callers switch on them
// exhaustively). Mirrors SuggestionRole.
enum class CommandBarRowRole {
  kDefault,
  kRemoteSuggestion,     // kSearchSuggestion / kNavigate from the engine.
  kExtensionAction,      // kAction: action_id "extension-action:<id>".
  kExtensionSuggestion,  // kSiteSearch inside an extension keyword scope.
  kDocument,             // kNavigate: an Easel or Note.
  kNewDocument,          // kNavigate: "New Google Doc" (opens `url`).
  kQuickCreate,          // kAction: New Easel / Note / Boost / Space.
};

struct CommandBarRow {
  std::string id;  // Stable across snapshots (keeps a moved selection).
  CommandBarRowKind kind = CommandBarRowKind::kNavigate;
  CommandBarRowRole role = CommandBarRowRole::kDefault;
  std::u16string title;
  // Drawn as "— <subtitle>" after the title.
  std::u16string subtitle;
  // Right side: "Switch to Tab", "Switch to Split View", or a Space name.
  std::u16string badge;
  // Right side for actions: shortcut keycaps, e.g. {u"⌘", u"T"}.
  std::vector<std::u16string> keycaps;
  // Favicon; null draws `fallback_glyph` on a plate.
  gfx::ImageSkia icon;
  secondary::Glyph fallback_glyph = secondary::Glyph::kGlobe;
  // Split View rows: one favicon cell per pane (2..4).
  std::vector<gfx::ImageSkia> pane_icons;
  // Targets.
  std::string url;
  std::optional<ItemID> tab_id;
  std::optional<SpaceID> space_id;
  std::string action_id;
  // Page whose favicon the row shows when `icon` is null (defaults to
  // `url` for page rows); looked up through the favicon callback.
  std::string favicon_url;
  std::string extension_id;
  // Extension omnibox rows: the text for chrome.omnibox.onInputEntered.
  std::string extension_content;
  std::string document_id;
};

struct CommandBarScopeTarget {
  CommandBarScope scope = CommandBarScope::kNone;
  std::string site_search_id;  // kSiteSearch only.
  std::u16string title;        // Chip text: "Wikipedia", "Actions", "Tabs".
  // True when the typed word is the site's exact name or keyword (the
  // trailing hint then reads "Tab or Space").
  bool exact_keyword = false;

  // An extension omnibox keyword scope: kSiteSearch with a site_search_id
  // of "extension:<id>" (ExtensionScopeId()).
  bool is_extension() const;
  std::optional<std::string> extension_id() const;
  static CommandBarScopeTarget ForExtension(const std::string& extension_id,
                                            const std::u16string& name);
};

struct CommandBarQuery {
  std::u16string text;  // The user's own text (never the completion).
  CommandBarMode mode = CommandBarMode::kNewTab;
  CommandBarScope scope = CommandBarScope::kNone;
  std::string site_search_id;
  // Rule T3a may fill `inline_completion` only when this is true.
  bool allows_inline_completion = false;
  uint64_t generation = 0;
};

struct CommandBarResults {
  std::vector<CommandBarRow> rows;  // At most 12 are kept; 5 show.
  // Full candidate text for the field (e.g. "github.com" for "gith"). Must
  // start with the query, ignoring ASCII case. Empty: no completion.
  std::u16string inline_completion;
  // Trailing "Search <Site>  [Tab]" hint; Tab enters this scope.
  std::optional<CommandBarScopeTarget> site_search_hint;
};

struct CommandBarIntent {
  CommandBarRow row;
  CommandBarDisposition disposition = CommandBarDisposition::kNewForegroundTab;
  int event_flags = 0;  // ui::EF_* of the key or click.
  std::u16string typed_text;
  CommandBarScope scope = CommandBarScope::kNone;
  std::string site_search_id;
};

struct CommandBarRequest {
  CommandBarMode mode = CommandBarMode::kNewTab;
  // kEditCurrentUrl: the current URL (shown fully selected).
  std::u16string initial_text;
  // kEditCurrentUrl: the page's favicon for the input's leading icon.
  gfx::ImageSkia current_favicon;
  // Cmd/Ctrl+L with the sidebar shown: the URL pill in this view's
  // coordinates. Empty: the centered New Tab card.
  std::optional<gfx::Rect> inline_anchor;
  // The same pill in screen coordinates (keyboard Cmd/Ctrl+L, a click on the
  // sidebar URL pill). Converted into this view on present and on every
  // layout, so the card follows a sidebar resize. `inline_anchor` wins.
  std::optional<gfx::Rect> anchor_in_screen;
  secondary::Appearance appearance;
  // Remote search suggestions are on for this Profile and window: the input
  // row shows the (i) button and Cmd/Ctrl+I opens the privacy footer.
  bool allows_remote_suggestions = false;
  // The footer's "Learn more … here." line links to Open's privacy page.
  bool shows_privacy_link = false;
};

// Favicon for a page URL (FaviconStore / ContentFaviconDriver / platform
// favicon service). Returns a null image when none is known yet; deliver a
// late one through OpenCommandBarView::UpdateFavicon().
using GetFaviconForUrlCallback =
    base::RepeatingCallback<gfx::ImageSkia(const GURL& page_url)>;

// Converts SuggestEngine rows (local or FetchRemoteSuggestions() results)
// into bar rows: kinds, roles, badges, keycaps and favicon URLs. Site Search
// hints are skipped (they belong in CommandBarResults::site_search_hint).
std::vector<CommandBarRow> CommandBarRowsFromSuggestions(
    const std::vector<Suggestion>& suggestions);

class CommandBarDelegate {
 public:
  virtual ~CommandBarDelegate() = default;

  // Synchronous fast path (local providers: open tabs, history, actions,
  // top domains, calculator). Called once per committed text change.
  // Remote providers deliver later through OpenCommandBarView::UpdateResults.
  virtual CommandBarResults QuerySuggestions(const CommandBarQuery& query) = 0;
  // Site Search lookup for Space (`exact_keyword_only`): the site whose exact
  // name or keyword equals `text` ("yt", "youtube"); a prefix returns empty.
  virtual std::optional<CommandBarScopeTarget> ResolveSiteSearch(
      std::u16string_view text,
      bool exact_keyword_only) = 0;
  // Return, a click, Cmd/Ctrl+Return, Alt+Return. The delegate must not
  // destroy the view synchronously.
  virtual void OnCommandBarIntent(const CommandBarIntent& intent) = 0;
  // The bar closed. Hide the overlay widget and return focus to the page.
  // `click_location` (this view's coordinates) is set for kClickOutside, so a
  // click on a sidebar tab can also select that tab (commandbar.md §4).
  virtual void OnCommandBarDismissed(
      CommandBarDismissReason reason,
      std::optional<gfx::Point> click_location) = 0;

  // Optional hooks (default: nothing).
  // Each committed text change that may want remote rows: start
  // SuggestEngine::FetchRemoteSuggestions() and answer with
  // UpdateRemoteRows(query.generation, ...). Cancel the previous request.
  virtual void OnCommandBarRemoteQuery(const CommandBarQuery& query) {}
  // Privacy footer: "Search Settings…" (the bar has closed), "Dismiss"
  // (record open.general.searchSuggestNoticeDismissed), and "here".
  virtual void OnCommandBarOpenSearchSettings() {}
  virtual void OnCommandBarDismissPrivacyNotice() {}
  virtual void OnCommandBarOpenPrivacyPage() {}
  // An extension keyword scope was entered (start the omnibox session:
  // OmniboxAPI onInputStarted) or left without committing (onInputCancelled).
  virtual void OnCommandBarExtensionScopeChanged(
      const std::string& extension_id,
      bool entered) {}
};

class OpenCommandBarView : public views::View,
                           public views::TextfieldController {
  METADATA_HEADER(OpenCommandBarView, views::View)

 public:
  explicit OpenCommandBarView(CommandBarDelegate* delegate);
  OpenCommandBarView(const OpenCommandBarView&) = delete;
  OpenCommandBarView& operator=(const OpenCommandBarView&) = delete;
  ~OpenCommandBarView() override;

  // Shows the bar in one frame, focuses the field and runs the first query.
  void Present(const CommandBarRequest& request);
  void Dismiss(CommandBarDismissReason reason);
  bool is_presented() const { return presented_; }
  CommandBarMode mode() const { return mode_; }
  CommandBarScope scope() const { return scope_; }

  // Late rows for the query with `generation` (remote suggestions). Ignored
  // when the text changed since.
  void UpdateResults(uint64_t generation, CommandBarResults results);
  // Merges search-engine rows into the current snapshot without a jarring
  // jump: row 1 and the inline completion stay, the previous remote rows are
  // replaced in place (after the typed search row), and a moved selection
  // keeps its row id. Applies to the current text (see generation()).
  void UpdateResults(std::vector<CommandBarRow> remote_rows);
  // The same, ignored unless `generation` is the current query's.
  void UpdateRemoteRows(uint64_t generation,
                        std::vector<CommandBarRow> remote_rows);
  // The current query's generation (CommandBarQuery::generation).
  uint64_t generation() const { return generation_; }

  // Favicons: rows with a null icon ask `callback` for their page's icon
  // when they arrive; UpdateFavicon() fills a late icon into every row (and
  // the Cmd/Ctrl+L input icon) of that page.
  void SetFaviconLookup(GetFaviconForUrlCallback callback);
  void UpdateFavicon(const GURL& page_url, const gfx::ImageSkia& icon);

  // Privacy footer (CC-42, D14): only the (i) button and Cmd/Ctrl+I show
  // it; it never opens by itself.
  void TogglePrivacyFooter();
  // Dismisses the privacy footer when visible and returns true; otherwise
  // returns false so the caller can dismiss the bar itself.
  bool HandleEscape();
  bool shows_privacy_footer() const { return shows_footer_; }
  // Updates the inline URL-pill anchor in screen coordinates while
  // kEditCurrentUrl is presented.
  void UpdateScreenAnchor(const gfx::Rect& anchor_in_screen);
  // Updates the remote-suggestion permission (after the notice dismissal).
  void SetAllowsRemoteSuggestions(bool allowed);
  bool allows_remote_suggestions() const { return allows_remote_; }
  // Enters a scope from code (e.g. a "Search Actions" command).
  void EnterScope(const CommandBarScopeTarget& target);
  void SetAppearance(const secondary::Appearance& appearance);

  // Automation / e2e frames.
  void InsertText(const std::u16string& text);
  gfx::Rect card_bounds() const { return card_; }
  std::u16string_view field_text() const;
  bool HasCompositionText() const;
  const std::u16string& typed_text() const { return typed_; }
  const std::u16string& completion() const { return completion_; }
  size_t selected_index() const { return selected_; }
  const std::vector<CommandBarRow>& rows() const { return results_.rows; }

  // Card frame in a view of `size` (commandbar.md §3.1, §12).
  static gfx::Rect ComputeCardBounds(const gfx::Size& size,
                                     CommandBarMode mode,
                                     size_t row_count,
                                     const std::optional<gfx::Rect>& anchor);
  // The same with the privacy footer open: panels with fewer than 2 rows
  // grow by its 61 pt (the band covers the list bottom otherwise).
  static gfx::Rect ComputeCardBounds(const gfx::Size& size,
                                     CommandBarMode mode,
                                     size_t row_count,
                                     const std::optional<gfx::Rect>& anchor,
                                     bool shows_footer);

  // views::View:
  void OnPaint(gfx::Canvas* canvas) override;
  void Layout(PassKey) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  void OnMouseMoved(const ui::MouseEvent& event) override;
  bool OnMouseWheel(const ui::MouseWheelEvent& event) override;

  // views::TextfieldController:
  void ContentsChanged(views::Textfield* sender,
                       const std::u16string& new_contents) override;
  bool HandleKeyEvent(views::Textfield* sender,
                      const ui::KeyEvent& key_event) override;

 private:
  bool is_inline() const { return inline_anchor_.has_value(); }
  bool is_extension_scope() const;
  // The (i) button shows: remote suggestions on, centered card, no Site
  // Search hint, footer closed.
  bool shows_info_button() const;
  void ResolveScreenAnchor();
  void FillFavicons(std::vector<CommandBarRow>& rows) const;
  void NormalizeRows(std::vector<CommandBarRow>& rows) const;
  void PaintFooter(gfx::Canvas* canvas);
  void PaintFooterButton(gfx::Canvas* canvas,
                         const gfx::Rect& bounds,
                         bool hovered,
                         const std::u16string& title);
  void PaintInfoButton(gfx::Canvas* canvas,
                       const gfx::Rect& bounds,
                       bool hovered);
  void OpenSearchSettings();
  void DismissPrivacyNotice();
  void OpenPrivacyPage();
  gfx::Rect FooterRect() const;
  gfx::Rect FooterLinkRect() const;

  void DismissInternal(CommandBarDismissReason reason,
                       std::optional<gfx::Point> click_location);
  void RunQuery();
  void ApplyResults(CommandBarResults results);
  void UpdateCompletion();
  void AcceptCompletion();
  void SetFieldText(const std::u16string& text,
                    size_t sel_start,
                    size_t sel_end);
  void MoveSelection(int delta);
  void EnsureSelectedVisible();
  void Commit(size_t index, int event_flags);
  void EnterScopeInternal(const CommandBarScopeTarget& target,
                          const std::u16string& restore_text);
  void ExitScope();
  std::optional<CommandBarScopeTarget> TabScopeTarget() const;
  void UpdatePlaceholder();
  void UpdateCard();

  // Painting.
  void PaintInputRow(gfx::Canvas* canvas);
  void PaintRows(gfx::Canvas* canvas);
  void PaintRow(gfx::Canvas* canvas,
                const CommandBarRow& row,
                const gfx::Rect& rect,
                bool selected);
  gfx::Rect RowRect(size_t visible_index) const;
  std::optional<size_t> RowAt(const gfx::Point& point) const;
  gfx::Rect ChipRect() const;
  int HintWidth() const;

  SkColor body_color() const;
  SkColor text_color() const;
  SkColor secondary_text_color() const;
  SkColor selection_fill() const;

  raw_ptr<CommandBarDelegate> delegate_;
  raw_ptr<views::Textfield> field_ = nullptr;
  raw_ptr<secondary::GlyphButton> close_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> info_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> footer_settings_ = nullptr;
  raw_ptr<secondary::PaintedButton> footer_dismiss_ = nullptr;
  raw_ptr<secondary::PaintedButton> footer_link_ = nullptr;
  GetFaviconForUrlCallback favicon_lookup_;
  std::optional<gfx::Rect> anchor_in_screen_;
  bool allows_remote_ = false;
  bool shows_footer_ = false;
  bool shows_privacy_link_ = false;

  bool presented_ = false;
  CommandBarMode mode_ = CommandBarMode::kNewTab;
  bool scope_from_command_ = false;
  std::optional<gfx::Rect> inline_anchor_;
  secondary::Appearance appearance_;
  gfx::ImageSkia current_favicon_;

  // Field state (§4.1).
  std::u16string typed_;
  std::u16string completion_;
  bool last_edit_was_insertion_ = false;
  bool allows_inline_ = false;
  // Field text and selection just before the last key press, so an edit
  // that replaces a trailing selection (Cmd+L's selected URL, the selected
  // completion) counts as an insertion at the end.
  std::u16string pre_edit_text_;
  gfx::Range pre_edit_selection_;
  bool last_key_was_paste_ = false;

  // Scope.
  CommandBarScope scope_ = CommandBarScope::kNone;
  std::string site_search_id_;
  std::u16string scope_title_;
  std::u16string text_before_scope_;

  // Rows.
  CommandBarResults results_;
  size_t selected_ = 0;
  bool user_moved_selection_ = false;
  size_t scroll_ = 0;
  uint64_t generation_ = 0;
  std::optional<gfx::Point> last_mouse_;

  gfx::Rect card_;

  base::WeakPtrFactory<OpenCommandBarView> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_COMMAND_BAR_VIEW_H_
