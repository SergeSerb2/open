// Copyright 2026 The Open Authors. All rights reserved.
//
// OpenPeekOverlayView: Peek, a page shown over the current page without
// becoming a sidebar tab (docs/m4.md; PeekMetrics in
// Packages/OpenKit/Sources/OpenDesign/FeatureMetrics.swift;
// Packages/OpenKit/Sources/OpenFeatures/PeekOverlayView.swift).
//
// Look: a 0.70 scrim over the overlay, a card 80 % of the content panel's
// width (2 pt top and bottom inset) holding a live `views::WebView`, and a
// floating vertical pill action rail outside the card's right edge:
//   Close (x), Expand to Tab (Cmd/Ctrl+O), Open in Split View, Copy URL,
//   and Open in Favorite / Space, plus a Back/Forward/Stack navigation pill
//   when navigating or stacked inside Peek.
//
// Card corner: 6 pt (PanelMetrics.cornerRadius, measured F0090).
//
// Hosting: lives in a `secondary::OverlayWidgetHost` (Alignment::kFill)
// covering the browser window's client area. Supports both externally-owned
// `WebContents*` via `Show()` and live owned `std::unique_ptr<WebContents>`
// adoption/transfer via `AdoptWebContents()` / `PushWebContents()` /
// `ReleaseWebContents()` so promoting Peek to a full tab or Split View never
// reloads the page.

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_PEEK_OVERLAY_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_PEEK_OVERLAY_VIEW_H_

#include <array>
#include <cstddef>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/menus/simple_menu_model.h"
#include "ui/views/view.h"
#include "url/gurl.h"

namespace content {
class NavigationHandle;
struct OpenURLParams;
class WebContents;
}  // namespace content

namespace views {
class MenuRunner;
class WebView;
}  // namespace views

namespace open_unified {

namespace motion {
class OpenSpringAnimator;
}  // namespace motion

namespace peek_metrics {
inline constexpr float kWidthFraction = 0.8f;
inline constexpr int kVerticalInset = 2;
inline constexpr int kButtonDiameter = 33;
inline constexpr int kButtonHitWidth = 35;
inline constexpr int kButtonGap = 13;
inline constexpr int kButtonTop = 9;
inline constexpr int kButtonPitch = 43;
inline constexpr int kRailPadding = 5;
inline constexpr int kRailWidth = 48;
inline constexpr int kRailGap = kButtonGap;
inline constexpr int kOuterMargin = 12;
inline constexpr int kHeaderHeight = 28;
inline constexpr int kNavPillGap = 10;
inline constexpr int kCardCornerRadius = 6;
inline constexpr size_t kMaxStackDepth = 5;
// Fitted F0090 shadow: opacity 0.18, radius 8 (blur 16), 2 pt down.
inline constexpr float kShadowAlpha = 0.18f;
inline constexpr float kShadowBlur = 16.f;
inline constexpr float kShadowOffsetY = 2.f;
}  // namespace peek_metrics

enum class PeekDismissReason {
  kEscape,
  kScrimClick,
  kCloseButton,
  kProgrammatic,
};

struct PeekSpaceChoice {
  SpaceID id;
  std::u16string title;
  std::optional<SpaceIcon> icon;
  SkColor color = SkColorSetRGB(0x49, 0x47, 0x5A);
};

class PeekDelegate {
 public:
  virtual ~PeekDelegate() = default;

  // Esc, a scrim click or Close. Track 6 hides the overlay widget and closes
  // (or sleeps) the Peek WebContents.
  virtual void OnPeekDismissed(PeekDismissReason reason) = 0;
  // Expand button or Cmd/Ctrl+O: promote the page to a real sidebar tab.
  // Call ReleaseWebContents() (for owned pages) or DetachWebContents() to
  // take the same live WebContents (DOM, scroll, media survive without reload).
  virtual void OnPeekExpandToTab() = 0;
  // Open in Split View: same live transfer into a split beside the current tab.
  virtual void OnPeekOpenInSplit() = 0;

  // Optional Wave E4 callbacks (default no-op for backward compatibility):

  // Fired right before OnPeekDismissed when a Peek entry closes, carrying the
  // last dismissed URL so the window can display a "Peek closed" Undo toast.
  virtual void OnPeekDismissedWithUndo(PeekDismissReason reason,
                                       const GURL& last_dismissed_url) {}
  // Copy URL button pressed. Return true if handled (e.g. clipboard + toast);
  // returning false lets OpenPeekOverlayView write |url| to the clipboard.
  virtual bool OnPeekCopyUrl(const GURL& url) { return false; }
  // Open in Favorite / Space action from the floating rail.
  virtual void OnPeekOpenInFavorite() {}
  virtual void OnPeekOpenInSpace(const SpaceID& space_id) {}
  // Fired when the Peek stack depth changes (push / pop / release).
  virtual void OnPeekStackChanged(size_t stack_depth) {}
};

class OpenPeekOverlayView : public views::View,
                            public ui::SimpleMenuModel::Delegate {
  METADATA_HEADER(OpenPeekOverlayView, views::View)

 public:
  enum Button : int {
    kCloseButton = 0,
    kExpandButton,
    kSplitButton,
    kCopyUrlButton,
    kFavoriteOrSpaceButton,
    kButtonCount,
  };

  explicit OpenPeekOverlayView(PeekDelegate* delegate);
  OpenPeekOverlayView(const OpenPeekOverlayView&) = delete;
  OpenPeekOverlayView& operator=(const OpenPeekOverlayView&) = delete;
  ~OpenPeekOverlayView() override;

  // Shows `contents` (not owned) in the card over `content_rect` (this
  // view's coordinates) and focuses the page. Preserved for backward
  // compatibility with callers that own their WebContents externally.
  void Show(content::WebContents* contents, const gfx::Rect& content_rect);

  // Adopts an owned live WebContents into Peek (zero reload) and displays it
  // in the card. Calling ReleaseWebContents() transfers the live WebContents
  // out with DOM, scroll position, and video/audio state intact.
  void AdoptWebContents(std::unique_ptr<content::WebContents> wc,
                        const gfx::Rect& content_rect);
  void AdoptWebContents(std::unique_ptr<content::WebContents> wc);

  // Pushes an owned live WebContents onto the multi-entry Peek stack (up to
  // peek_metrics::kMaxStackDepth). Prior entries stay alive underneath.
  bool PushWebContents(std::unique_ptr<content::WebContents> wc);

  // Pops the top entry from the Peek stack. Records its URL in
  // last_dismissed_url(). If entries remain, reveals the previous entry; if
  // the stack becomes empty, hides the overlay and notifies the delegate.
  bool PopStack(PeekDismissReason reason);

  // Hides and detaches/clears all Peek stack entries.
  void Hide();
  bool is_showing() const { return showing_; }
  void SetContentRect(const gfx::Rect& content_rect);
  // Controls take the Space's light title color; the scrim its dark
  // background at 0.70 (BrowserWindowController peek styling).
  void SetAppearance(const secondary::Appearance& appearance);

  // Spaces shown in the "Open in Favorite / Space" floating rail menu.
  void SetSpaceChoices(std::vector<PeekSpaceChoice> spaces);

  // Detaches and transfers ownership of the top live Peek WebContents for
  // zero-reload promotion (Expand to Tab / Open in Split View). If the top
  // entry was adopted via AdoptWebContents()/PushWebContents(), returns the
  // owned unique_ptr; otherwise detaches and returns nullptr (call
  // DetachWebContents() for non-owned pages). Hides the overlay if the stack
  // becomes empty, or reveals the underlying stack entry.
  std::unique_ptr<content::WebContents> ReleaseWebContents();

  // Detaches and returns a non-owned WebContents* for callers that own the
  // WebContents externally via Show().
  content::WebContents* DetachWebContents();

  // The currently active Peek WebContents (top of stack), or nullptr.
  content::WebContents* active_web_contents() const;
  views::WebView* web_view() { return web_view_; }

  // Navigation & stack accessors.
  size_t stack_depth() const { return stack_.size(); }
  bool CanGoBack() const;
  bool CanGoForward() const;
  void GoBack();
  void GoForward();

  // URL of the most recently dismissed Peek entry (for an Undo toast).
  const GURL& last_dismissed_url() const { return last_dismissed_url_; }
  std::optional<GURL> TakeLastDismissedUrl();

  // Smooth fade-out dismiss (runs over motion::kPeekDismiss when a compositor
  // is present and reduced motion is off, then pops/dismisses).
  void DismissSmooth(PeekDismissReason reason);

  gfx::Rect card_bounds() const { return card_; }
  gfx::Rect GetButtonBounds(Button button) const;
  gfx::Rect rail_bounds() const { return rail_bounds_; }
  gfx::Rect nav_pill_bounds() const { return nav_pill_bounds_; }

  // Card frame for a content panel (PeekOverlayView.layout()).
  static gfx::Rect ComputeCardBounds(const gfx::Rect& content_rect);

  // views::View:
  void OnPaint(gfx::Canvas* canvas) override;
  void Layout(PassKey) override;
  ui::Cursor GetCursor(const ui::MouseEvent& event) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  bool OnKeyPressed(const ui::KeyEvent& event) override;
  bool AcceleratorPressed(const ui::Accelerator& accelerator) override;
  bool CanHandleAccelerators() const override;

  // ui::SimpleMenuModel::Delegate:
  void ExecuteCommand(int command_id, int event_flags) override;
  bool IsCommandIdEnabled(int command_id) const override;

 private:
  class StackEntryDelegate;
  friend class StackEntryDelegate;

  struct StackEntry {
    StackEntry();
    ~StackEntry();
    StackEntry(StackEntry&&) noexcept;
    StackEntry& operator=(StackEntry&&) noexcept;

    std::unique_ptr<content::WebContents> owned_contents;
    raw_ptr<content::WebContents> raw_contents = nullptr;
    std::unique_ptr<StackEntryDelegate> wc_delegate;
    GURL url;
    std::u16string title;
  };

  void Dismiss(PeekDismissReason reason);
  void PressButton(Button button);
  void ShowTopEntry();
  void SyncNavButtons();
  void ShowFavoriteOrSpaceMenu();
  void OnEntryNavigated(content::WebContents* contents);
  void OnEntryLoadProgress(content::WebContents* contents, double progress);
  void OnEntryClosed(content::WebContents* contents);
  SkColor CardSurfaceColor() const;
  std::u16string CurrentHostLabel() const;
  content::WebContents* HandleChildOpenUrl(
      content::WebContents* source,
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)>
          navigation_handle_callback,
      bool open_in_new_peek);
  content::WebContents* HandleChildNewContents(
      std::unique_ptr<content::WebContents> new_contents);
  void StartOpacityAnimation(double from,
                             double to,
                             double duration_sec,
                             std::optional<PeekDismissReason> finish_dismiss);
  void ApplyOpacityStep(double value);
  void OnOpacityAnimationSettled();
  void PaintStackBadge(gfx::Canvas* canvas,
                       const gfx::Rect& bounds,
                       bool hovered);
  static GURL CurrentUrlFor(content::WebContents* contents,
                            const GURL& fallback);

  raw_ptr<PeekDelegate> delegate_;
  raw_ptr<views::WebView> web_view_ = nullptr;
  std::array<raw_ptr<secondary::GlyphButton>, kButtonCount> buttons_{};
  raw_ptr<secondary::GlyphButton> back_button_ = nullptr;
  raw_ptr<secondary::GlyphButton> forward_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> stack_badge_button_ = nullptr;

  std::vector<StackEntry> stack_;
  GURL last_dismissed_url_;
  std::vector<PeekSpaceChoice> space_choices_;
  std::unique_ptr<ui::SimpleMenuModel> space_menu_model_;
  std::unique_ptr<views::MenuRunner> space_menu_runner_;

  secondary::Appearance appearance_;
  gfx::Rect content_rect_;
  gfx::Rect card_;
  gfx::Rect rail_bounds_;
  gfx::Rect nav_pill_bounds_;
  bool showing_ = false;
  bool loading_ = false;
  double load_progress_ = 0.0;

  std::unique_ptr<motion::OpenSpringAnimator> opacity_animator_;
  std::optional<PeekDismissReason> pending_dismiss_reason_;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_PEEK_OVERLAY_VIEW_H_
