// Copyright 2026 The Open Authors. All rights reserved.
//
// Track 5 secondary hot-path views, part 1:
//
//   A. `open_unified::secondary` — small shared primitives used by every
//      Track 5 view (colors, fonts, Open's own procedural glyphs, a glyph
//      button, and `OverlayWidgetHost`, a child TYPE_CONTROL widget that hosts
//      an overlay above the page). They live here so the six Track 5 file
//      pairs stay self-contained and never depend on Track 4's private
//      headers.
//   B. `OpenPaneChromeView` — the 32 pt page-tinted bar of a split pane.
//   C. `OpenSplitContainerView` — hosts 1..4 live `views::WebView` panes.
//
// Values come from Packages/OpenKit/Sources/OpenDesign/FeatureMetrics.swift
// (`SplitMetrics`), Metrics.swift (`PanelMetrics`) and
// Packages/OpenKit/Sources/OpenFeatures/{PaneChromeView,SplitLayout,
// SplitDividerView,WebContentContainer}.swift.
//
// Why overlays use a child widget: on Aura and on macOS the page's native
// view takes every mouse event inside its bounds, even where a Views layer is
// painted above it. Overlays that need clicks over the page (command bar,
// Peek, find bar, toasts, Ctrl+Tab switcher) therefore live in a
// TYPE_CONTROL child widget of the browser widget, the same approach as
// Chromium's own find bar (DropdownBarHost). Child widgets share the
// top-level FocusManager, so text fields inside them take keyboard focus.

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_SPLIT_CONTAINER_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_SPLIT_CONTAINER_VIEW_H_

#include <cstddef>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "build/build_config.h"
#include "open_unified/core/model/open_types.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/dragdrop/mojom/drag_drop_types.mojom-forward.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/events/event_constants.h"
#include "ui/gfx/font.h"
#include "ui/gfx/font_list.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/vector2d_f.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/menus/simple_menu_model.h"
#include "ui/views/controls/button/button.h"
#include "ui/views/view.h"
#include "ui/views/view_observer.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_observer.h"
#include "url/gurl.h"

namespace content {
class WebContents;
}  // namespace content

namespace gfx {
class Canvas;
}  // namespace gfx

namespace ui {
class ClipboardFormatType;
class DropTargetEvent;
class LayerTreeOwner;
class OSExchangeData;
}  // namespace ui

namespace views {
class MenuRunner;
class WebView;
class Widget;
}  // namespace views

namespace open_unified {

// ===========================================================================
// A. Shared secondary-view primitives.
// ===========================================================================
namespace secondary {

// The platform's primary shortcut modifier: Cmd on macOS, Ctrl elsewhere.
#if BUILDFLAG(IS_MAC)
inline constexpr int kPrimaryModifier = ui::EF_COMMAND_DOWN;
#else
inline constexpr int kPrimaryModifier = ui::EF_CONTROL_DOWN;
#endif

// "⌘O" on macOS, "Ctrl+O" elsewhere.
std::u16string PrimaryShortcutLabel(char16_t key);

// True when `flags` holds the primary modifier (Cmd on macOS, Ctrl elsewhere).
bool HasPrimaryModifier(int flags);

// --- Color helpers ---------------------------------------------------------
SkColor ToSkColor(const RGBAColor& color);
SkColor WithAlpha(SkColor color, float alpha);
// Mixes `a` toward `b` by `t` (0 = a, 1 = b), alpha included.
SkColor Mix(SkColor a, SkColor b, float t);
// Rec. 709 luma below 0.5: the page or plate needs light glyphs.
bool IsDark(SkColor color);

// Appearance for every Track 5 view. Track 6 fills it from the focused
// Space's theme (Track 4's OpenThemeMath) and the window's light/dark mode.
// Defaults are Open's default theme.
struct Appearance {
  bool dark = false;
  // D3 SpaceAccent default theme: #6F66D9 light, #5148C4 dark.
  SkColor accent = SkColorSetRGB(0x6F, 0x66, 0xD9);
  SkColor dark_accent = SkColorSetRGB(0x51, 0x48, 0xC4);
  // Split pane focus ring (F0081 default Space indigo #3139FF).
  SkColor focus_ring = SkColorSetRGB(0x31, 0x39, 0xFF);
  // Toast fill (SpaceThemeStyle.defaultDarkToastFill, A0440): #442B68 ->
  // #332350 with white text.
  SkColor toast_fill_top = SkColorSetRGB(0x44, 0x2B, 0x68);
  SkColor toast_fill_bottom = SkColorSetRGB(0x33, 0x23, 0x50);
  SkColor toast_text = SK_ColorWHITE;
  // PeekMetrics.defaultControls #050627, defaultGlyph #F0F1FF,
  // defaultScrim #000013 at 0.70.
  SkColor peek_controls = SkColorSetRGB(0x05, 0x06, 0x27);
  SkColor peek_glyph = SkColorSetRGB(0xF0, 0xF1, 0xFF);
  SkColor peek_scrim = SkColorSetARGB(0xB3, 0x00, 0x00, 0x13);

  SkColor ActiveAccent() const { return dark ? dark_accent : accent; }
};

// --- Type ------------------------------------------------------------------
// The system UI font at `size` points with `weight`.
gfx::FontList FontOfSize(int size,
                         gfx::Font::Weight weight = gfx::Font::Weight::NORMAL);
int TextWidth(std::u16string_view text, const gfx::FontList& font);
// Draws one line of text vertically centered in `rect`, tail-elided to its
// width. `align` is gfx::Canvas::TEXT_ALIGN_{LEFT,CENTER,RIGHT}.
// Subpixel (LCD) text is off: Track 5 views paint on translucent layers.
void DrawText(gfx::Canvas* canvas,
              std::u16string_view text,
              const gfx::FontList& font,
              SkColor color,
              const gfx::Rect& rect,
              int align = 0);

// --- Shapes ----------------------------------------------------------------
void FillRoundRect(gfx::Canvas* canvas,
                   const gfx::RectF& rect,
                   float radius,
                   SkColor color);
void StrokeRoundRect(gfx::Canvas* canvas,
                     const gfx::RectF& rect,
                     float radius,
                     SkColor color,
                     float width);
// Vertical two-stop gradient fill.
void FillRoundRectGradient(gfx::Canvas* canvas,
                           const gfx::RectF& rect,
                           float radius,
                           SkColor top,
                           SkColor bottom);
// One Gaussian drop shadow under a round rect (blur = 2 sigma, Chromium's
// gfx::ShadowValue convention), then the fill on top.
void FillRoundRectWithShadow(gfx::Canvas* canvas,
                             const gfx::RectF& rect,
                             float radius,
                             SkColor fill,
                             SkColor shadow_color,
                             float shadow_offset_y,
                             float shadow_blur);
// Draws `image` scaled into `rect` with filtering. No-op for a null image.
void DrawImageInRect(gfx::Canvas* canvas,
                     const gfx::ImageSkia& image,
                     const gfx::Rect& rect);

// --- Glyphs ----------------------------------------------------------------
// Open's own line glyphs, drawn procedurally in Skia (no copied assets,
// CLAUDE.md rule 1). Each glyph fills a square centered in `box`.
enum class Glyph {
  kNone,
  kBack,
  kForward,
  kReload,
  kStop,
  kClose,
  kLink,
  kCopy,
  kSiteControl,
  kSplit,
  kSplitVertical,
  kSwap,
  kSeparate,
  kChevronDown,
  kChevronUp,
  kChevronRight,
  kExpand,
  kSearch,
  kGlobe,
  kPlus,
  kMinus,
  kSquare,
  kCamera,
  kMicrophone,
  kLocation,
  kBell,
  kPopup,
  kShield,
  kBoost,
  kCapture,
  kGear,
  kTrash,
  kLock,
  kPuzzle,
  kUndo,
  kCheck,
  kEquals,
  kBolt,
  kStar,
  kDownload,
  kStack,
};
// `stroke_width` 0 picks a width from the glyph size (about 1/11 of it,
// clamped to 1.2..2 pt).
void PaintGlyph(gfx::Canvas* canvas,
                Glyph glyph,
                const gfx::RectF& box,
                SkColor color,
                float stroke_width = 0.f);

// A borderless icon button that paints one Open glyph, with an optional
// plate (hover-only rounded rect, always-on rounded rect, or circle).
class GlyphButton : public views::Button {
  METADATA_HEADER(GlyphButton, views::Button)

 public:
  enum class Plate {
    kNone,
    kHoverRounded,
    kRounded,
    kCircle,
  };

  GlyphButton(PressedCallback callback,
              Glyph glyph,
              const std::u16string& accessible_name);
  GlyphButton(const GlyphButton&) = delete;
  GlyphButton& operator=(const GlyphButton&) = delete;
  ~GlyphButton() override;

  void SetGlyph(Glyph glyph);
  Glyph glyph() const { return glyph_; }
  void SetGlyphColor(SkColor color);
  void SetGlyphSize(float size);
  void SetGlyphOffset(const gfx::Vector2dF& offset);
  // Optional macOS SF Symbol name rendered via open_unified::glyphs on macOS,
  // falling back automatically to `glyph_` on Windows/Linux.
  void SetSystemSymbol(std::string symbol_name, float point_size = 0.f);
  void SetPlate(Plate plate, SkColor fill, float radius);
  void SetHoverFill(SkColor fill);
  // Disabled glyphs draw at alpha 0.24 (PaneChromeView.ActionButton).
  void SetDimsWhenDisabled(bool dims);

  // views::Button:
  void PaintButtonContents(gfx::Canvas* canvas) override;

 private:
  Glyph glyph_;
  std::string system_symbol_name_;
  float system_symbol_point_size_ = 0.f;
  SkColor glyph_color_ = SkColorSetA(SK_ColorBLACK, 0x8C);
  float glyph_size_ = 16.f;
  gfx::Vector2dF glyph_offset_;
  Plate plate_ = Plate::kHoverRounded;
  SkColor plate_fill_ = SK_ColorTRANSPARENT;
  float plate_radius_ = 6.f;
  SkColor hover_fill_ = SkColorSetA(SK_ColorBLACK, 0x12);
  bool dims_when_disabled_ = true;
};

// A borderless button whose whole look comes from `painter`. Used for
// painted controls that still need focus, keyboard and accessibility
// (Little Open's pill and chip, Site Control tiles and rows).
class PaintedButton : public views::Button {
  METADATA_HEADER(PaintedButton, views::Button)

 public:
  using Painter = base::RepeatingCallback<
      void(gfx::Canvas* canvas, const gfx::Rect& bounds, bool hovered)>;

  PaintedButton(PressedCallback callback,
                Painter painter,
                const std::u16string& accessible_name);
  PaintedButton(const PaintedButton&) = delete;
  PaintedButton& operator=(const PaintedButton&) = delete;
  ~PaintedButton() override;

  void SetPainter(Painter painter);

  // views::Button:
  void PaintButtonContents(gfx::Canvas* canvas) override;

 private:
  Painter painter_;
};

// Hosts one overlay view in a frameless, translucent TYPE_CONTROL child
// widget of `parent`. Bounds are in the parent widget's client coordinates.
// The contents view's insets (an EmptyBorder) are treated as shadow margin:
// the inset rect, not the widget, is aligned to the anchor.
//
// Focus: an activatable overlay (Command Bar, Find bar, Peek, Boost and
// Space editors) takes key focus when shown, and holds
// `parent->LockPaintAsActive()` while it is visible, so the browser window
// never paints inactive (no dark flash, no grey traffic lights) under it.
// A non-activatable overlay (toasts, the Ctrl+Tab switcher) is created with
// Activatable::kNo and shown with ShowInactive(): it never steals keyboard
// focus from the page.
class OverlayWidgetHost : public views::ViewObserver,
                          public views::WidgetObserver {
 public:
  enum class Alignment {
    kFill,       // Widget = anchor (full-window overlays).
    kCenter,     // Preferred size, centered in anchor.
    kTopCenter,  // Preferred size, centered horizontally at anchor top.
    kTopRight,   // Preferred size, at anchor's top-right corner.
  };

  // `activatable` defaults by name: "OpenToasts" and "OpenTabSwitcher" are
  // non-activatable, every other overlay is activatable.
  OverlayWidgetHost(views::Widget* parent,
                    std::unique_ptr<views::View> contents,
                    std::string_view name);
  OverlayWidgetHost(views::Widget* parent,
                    std::unique_ptr<views::View> contents,
                    std::string_view name,
                    bool activatable);
  OverlayWidgetHost(const OverlayWidgetHost&) = delete;
  OverlayWidgetHost& operator=(const OverlayWidgetHost&) = delete;
  ~OverlayWidgetHost() override;

  views::View* contents() { return contents_; }
  views::Widget* widget() { return widget_.get(); }

  void SetAnchor(const gfx::Rect& anchor_in_parent, Alignment alignment);
  // Shows the widget on top of its siblings without animation.
  void Show();
  void Hide();
  bool IsVisible() const;
  bool activatable() const { return activatable_; }

  // The default activation for an overlay `name` (see the constructor).
  static bool DefaultActivatableFor(std::string_view name);

  // views::ViewObserver:
  void OnViewPreferredSizeChanged(views::View* observed_view) override;

  // views::WidgetObserver:
  void OnWidgetVisibilityChanged(views::Widget* widget, bool visible) override;
  void OnWidgetDestroying(views::Widget* widget) override;

 private:
  void ApplyBounds();
  void UpdatePaintAsActiveLock(bool visible);

  bool activatable_ = true;
  raw_ptr<views::Widget> parent_ = nullptr;
  // Held while an activatable overlay is visible.
  std::unique_ptr<views::Widget::PaintAsActiveLock> paint_as_active_lock_;
  base::ScopedObservation<views::Widget, views::WidgetObserver>
      widget_observation_{this};
  std::unique_ptr<views::Widget> widget_;
  raw_ptr<views::View> contents_ = nullptr;
  gfx::Rect anchor_;
  Alignment alignment_ = Alignment::kFill;
  base::ScopedObservation<views::View, views::ViewObserver> observation_{this};
};

}  // namespace secondary

// ===========================================================================
// B/C. Split View.
// ===========================================================================

// SplitMetrics (FeatureMetrics.swift) and PanelMetrics (Metrics.swift).
namespace split_metrics {
inline constexpr int kGap = 10;
inline constexpr int kBarHeight = 32;
inline constexpr int kRingWidth = 2;
inline constexpr int kMinimumPane = 200;
inline constexpr int kPanelCornerRadius = 6;
inline constexpr gfx::Rect kBack{5, 4, 32, 24};
inline constexpr gfx::Rect kForward{42, 4, 32, 24};
inline constexpr gfx::Rect kReload{79, 4, 32, 24};
// Copy button 3 pt before the host text; a mirrored 24 pt slot after it.
inline constexpr int kHostSlot = 25;
inline constexpr int kBarControlGap = 4;
inline constexpr int kHostMinimumWidth = 28;
// Right-side controls, from the bar's right edge (PaneChromeView.layout()).
inline constexpr int kSiteControlFromRight = 105;  // [w-105, 2, 32, 28]
inline constexpr int kSplitMenuFromRight = 69;     // [w-69, 4, 32, 24]
inline constexpr int kCloseFromRight = 37;         // [w-37, 4, 32, 24]
inline constexpr int kToolbarSiteControlFromRight = 37;
}  // namespace split_metrics

enum class PaneCommand {
  kBack,
  kForward,
  kReload,
  kStop,
  kCopyUrl,
  kSiteControl,
  kAddSplit,
  kSwapPanes,
  kToggleOrientation,
  kSeparateTab,
  kClosePane,
};

enum class SplitDropZone {
  kLeft,
  kRight,
  kTop,
  kBottom,
  kReplacePane,
};

enum class PaneDevToolsDock {
  kBottom,
  kRight,
  kOverlay,
};

// One pane of the active Tab or Split.
struct SplitPaneSpec {
  ItemID tab_id;
  // The live page, or null for a placeholder or sleeping tab (the pane then
  // paints its page color or empty-pane fallback card). Not owned.
  raw_ptr<content::WebContents, DanglingUntriaged> web_contents = nullptr;
  // Bar label. Empty: derived from the committed URL host without "www.".
  // Track 6 passes "Note" / "Easel" for open:// pages (bug sweep r7 AB-06).
  std::u16string host_label;
  // TabLiveState.page_background_color. Empty: the renderer's reported
  // background, else the presentation's fallback color.
  std::optional<SkColor> page_background;
  bool site_controls_available = true;
  // Notes have no shareable address: no Copy button.
  bool hides_copy = false;
  // Explicit empty-pane placeholder (e.g., "Add Split View" with no tab yet).
  // When true, or when `web_contents == nullptr && !is_sleeping`, the pane
  // displays the empty-pane card ("Drop a tab or press Cmd/Ctrl+T").
  bool is_empty_placeholder = false;
  // True when `web_contents` is null only because the tab is sleeping/loading.
  bool is_sleeping = false;
};

struct SplitPresentation {
  // Empty for a single tab.
  std::optional<ItemID> split_id;
  SplitOrientation orientation = SplitOrientation::kHorizontal;
  // Split.fractions; empty means equal.
  std::vector<double> fractions;
  // 1 pane for a single tab, 2..4 for a split.
  std::vector<SplitPaneSpec> panes;
  std::optional<ItemID> focused_pane_id;
  // A single tab shows the optional content toolbar (BrowserWindowState
  // .shows_toolbar): the pane bar without Split Menu and Close.
  bool show_single_pane_toolbar = false;
  // The Space's light background, else white (PaneChromeView.fallbackColor).
  SkColor fallback_page_color = SK_ColorWHITE;
  // The ring on the focused pane. Track 6 passes the Space accent;
  // the default is #3139FF.
  SkColor focus_ring_color = SkColorSetRGB(0x31, 0x39, 0xFF);
};

class OpenSplitContainerDelegate {
 public:
  virtual ~OpenSplitContainerDelegate() = default;

  // One undoable change, sent on mouse-up only when the fractions changed.
  virtual void OnSplitFractionsCommitted(
      const ItemID& split_id,
      const std::vector<double>& fractions) = 0;
  // Every drag step (up to display rate). Optional; no model write expected.
  virtual void OnSplitFractionsLive(const ItemID& split_id,
                                    const std::vector<double>& fractions) {}
  // The user clicked a pane bar or focused a pane's page.
  virtual void OnPaneFocusRequested(const std::optional<ItemID>& split_id,
                                    const ItemID& tab_id) = 0;
  // A bar control or Split Menu item. `anchor` is the pressed control (for
  // the Site Control bubble). Return false to let the container run the
  // default engine action (Back, Forward, Reload, Stop on the WebContents).
  virtual bool OnPaneCommand(const std::optional<ItemID>& split_id,
                             const ItemID& tab_id,
                             PaneCommand command,
                             views::View* anchor) = 0;

  // Optional Wave E4 callbacks (default no-op for backward compatibility):

  // The user clicked "Open Command Bar" inside an empty placeholder pane.
  virtual void OnEmptyPaneOpenCommandBar(const std::optional<ItemID>& split_id,
                                         const ItemID& tab_id) {}
  // Two panes swapped order via SwapPanes() or drag-handle swap.
  virtual void OnPanesSwapped(const ItemID& split_id,
                              size_t index_a,
                              size_t index_b) {}
  // Drag-to-split negotiation for sidebar tab or URL drags over the panel.
  virtual bool CanDropInSplit(const std::optional<ItemID>& dragged_tab_id,
                              const GURL& dragged_url,
                              SplitDropZone zone,
                              std::optional<size_t> target_pane_index) {
    return false;
  }
  virtual bool OnDropInSplit(const std::optional<ItemID>& dragged_tab_id,
                             const GURL& dragged_url,
                             SplitDropZone zone,
                             std::optional<size_t> target_pane_index) {
    return false;
  }
};

// The 32 pt bar on top of a split pane (or the single-pane content toolbar).
// Its fill is the page's background color; glyphs switch to light on a dark
// page. Focused pane: Back, Forward, Reload, Copy URL + host, Site Control,
// Split Menu, Close. Unfocused pane: Back, Forward, Copy + host, Close
// (F0081). A narrow bar drops Reload, Forward, Site Control, Split Menu, Back
// in that order; Close stays (PaneChromeView.squeezeOrder).
class OpenPaneChromeView : public views::View,
                           public ui::SimpleMenuModel::Delegate {
  METADATA_HEADER(OpenPaneChromeView, views::View)

 public:
  enum class Role {
    kPane,
    kToolbar,
  };

  enum Control : int {
    kBackControl = 0,
    kForwardControl,
    kReloadControl,
    kCopyControl,
    kSiteControlControl,
    kSplitMenuControl,
    kCloseControl,
    kControlCount,
  };

  struct State {
    bool focused = false;
    bool can_go_back = false;
    bool can_go_forward = false;
    bool is_loading = false;
    bool site_controls_available = true;
    bool hides_copy = false;
    std::u16string host;
    SkColor background = SK_ColorWHITE;
    size_t pane_count = 1;
    SplitOrientation orientation = SplitOrientation::kHorizontal;

    bool operator==(const State&) const = default;
  };

  using CommandCallback =
      base::RepeatingCallback<void(PaneCommand command, views::View* anchor)>;

  OpenPaneChromeView(Role role, CommandCallback callback);
  OpenPaneChromeView(const OpenPaneChromeView&) = delete;
  OpenPaneChromeView& operator=(const OpenPaneChromeView&) = delete;
  ~OpenPaneChromeView() override;

  void SetRole(Role role);
  Role role() const { return role_; }
  void SetState(const State& state);
  const State& state() const { return state_; }
  // Runs when the bar or any of its controls is clicked (focuses the pane).
  void SetFocusRequestCallback(base::RepeatingClosure callback);

  // Drag-handle pane swap callbacks (coordinates in this chrome view).
  using DragCallback =
      base::RepeatingCallback<void(const gfx::Point& location_in_chrome,
                                   bool finished)>;
  void SetDragSwapCallback(DragCallback callback);

  // The Site Control button: anchor for OpenSiteControlBubble.
  views::View* site_control_anchor();
  // True when a control is currently shown (automation and e2e frames).
  bool IsControlVisible(Control control) const;
  gfx::Rect GetControlBounds(Control control) const;
  gfx::Rect host_label_bounds() const { return host_rect_; }

  // views::View:
  void OnPaint(gfx::Canvas* canvas) override;
  void Layout(PassKey) override;
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  bool OnMouseDragged(const ui::MouseEvent& event) override;
  void OnMouseReleased(const ui::MouseEvent& event) override;
  void OnMouseCaptureLost() override;

  // ui::SimpleMenuModel::Delegate:
  void ExecuteCommand(int command_id, int event_flags) override;
  bool IsCommandIdEnabled(int command_id) const override;

 private:
  void Press(Control control);
  void ShowSplitMenu();
  void ApplyColors();
  bool IsRoleHidden(Control control) const;

  Role role_;
  CommandCallback callback_;
  base::RepeatingClosure focus_callback_;
  DragCallback drag_swap_callback_;
  gfx::Point drag_press_origin_;
  bool drag_swap_active_ = false;
  State state_;
  std::vector<raw_ptr<secondary::GlyphButton>> buttons_;
  gfx::Rect host_rect_;
  bool host_fits_ = false;
  bool draws_on_dark_ = false;
  std::unique_ptr<ui::SimpleMenuModel> menu_model_;
  std::unique_ptr<views::MenuRunner> menu_runner_;
};

namespace split_internal {
class SplitPaneView;
class SplitPaneShadowView;
class SplitDividerView;
class SplitDropOverlayView;
}  // namespace split_internal

// Hosts the active Tab (one pane) or Split (2..4 panes) in the content panel.
//
// Single tab: the page fills the bounds with a 6 pt rounded clip and no bar
// (or the 32 pt top mini-toolbar when `SetSinglePaneToolbarVisible(true)` is
// set for View -> Show Toolbar).
// Split: panes side by side (kHorizontal) or stacked (kVertical), 10 pt
// gaps, 200 pt minimum pane (panes shrink equally when the panel is too
// narrow), a 32 pt page-tinted bar per pane, and a 2 pt ring on the focused
// pane. Dragging a gap resizes its two panes live (bounds only, no layout
// pass through the web subtree) and commits once on mouse-up.
class OpenSplitContainerView : public views::View {
  METADATA_HEADER(OpenSplitContainerView, views::View)

 public:
  explicit OpenSplitContainerView(OpenSplitContainerDelegate* delegate);
  OpenSplitContainerView(const OpenSplitContainerView&) = delete;
  OpenSplitContainerView& operator=(const OpenSplitContainerView&) = delete;
  ~OpenSplitContainerView() override;

  // Replaces what the container shows. Panes are matched by tab id, so a
  // page that stays keeps its attached WebView (no reattach, no reload).
  void SetPresentation(SplitPresentation presentation);
  const SplitPresentation& presentation() const { return presentation_; }

  // Live updates without a full presentation.
  void SetFocusedPane(const ItemID& tab_id);
  void SetPaneBackgroundColor(const ItemID& tab_id, SkColor color);
  void SetPaneHostLabel(const ItemID& tab_id, const std::u16string& host);
  void SetPaneSiteControlsAvailable(const ItemID& tab_id, bool available);

  // Shows or hides the single-pane top mini-toolbar (View -> Show Toolbar /
  // toggle-toolbar) when not in Split View, without detaching the WebContents.
  void SetSinglePaneToolbarVisible(bool shows_toolbar);
  bool single_pane_toolbar_visible() const {
    return presentation_.show_single_pane_toolbar;
  }

  // Drag-to-split translucent drop-target preview overlay.
  void SetDropZonePreview(
      std::optional<SplitDropZone> zone,
      std::optional<size_t> target_pane_index = std::nullopt);
  std::optional<SplitDropZone> drop_zone_preview() const {
    return drop_zone_preview_;
  }
  std::optional<size_t> drop_target_pane_index() const {
    return drop_target_pane_index_;
  }
  void SetDropOverlayAccentColor(SkColor color);
  // Theme content polarity (true = dark Space, false = light Space) for the
  // divider grabber pill and unfocused split-pane inset border.
  void SetDarkContent(bool dark);

  // Swaps two panes in place (2..4 panes) without detaching or reloading
  // their WebContents. Notifies OpenSplitContainerDelegate::OnPanesSwapped.
  bool SwapPanes(size_t index_a, size_t index_b);

  // Indexed pane accessors and Split View DevTools hosting hooks.
  size_t pane_count() const { return panes_.size(); }
  views::WebView* GetWebViewForPane(size_t index);
  OpenPaneChromeView* GetPaneChromeForPane(size_t index);
  std::optional<ItemID> GetTabIdForPane(size_t index) const;
  void SetPaneDevToolsOverlay(size_t index,
                              views::View* devtools_view,
                              PaneDevToolsDock dock = PaneDevToolsDock::kBottom,
                              float ratio = 0.35f);
  void SetPaneDevToolsOverlay(const ItemID& tab_id,
                              views::View* devtools_view,
                              PaneDevToolsDock dock = PaneDevToolsDock::kBottom,
                              float ratio = 0.35f);
  void SetPaneDevToolsOverlayOwned(
      size_t index,
      std::unique_ptr<views::View> devtools_view,
      PaneDevToolsDock dock = PaneDevToolsDock::kBottom,
      float ratio = 0.35f);
  void ClearPaneDevToolsOverlay(size_t index);
  void ClearPaneDevToolsOverlay(const ItemID& tab_id);
  views::View* GetPaneDevToolsOverlay(size_t index) const;

  views::WebView* GetWebViewForTab(const ItemID& tab_id);
  OpenPaneChromeView* GetPaneChromeForTab(const ItemID& tab_id);
  // Pane frames in this view's coordinates, in pane order (automation).
  std::vector<gfx::Rect> GetPaneBounds() const;
  // The fractions currently on screen (during a drag, the live ones).
  const std::vector<double>& current_fractions() const {
    return live_fractions_;
  }

  // Pure drop-zone hit-testing (port of SplitDropOverlayView.zone(at:)).
  static SplitDropZone ComputeDropZoneAt(const gfx::Rect& bounds,
                                         const gfx::Point& point);
  static gfx::Rect ComputeDropPreviewRect(
      const gfx::Rect& container_bounds,
      const std::vector<gfx::Rect>& pane_bounds,
      SplitDropZone zone,
      std::optional<size_t> target_pane_index);

  // Pure layout (port of SplitLayout.frames): integer boundaries, the last
  // pane takes the remainder; fractions are normalized; panes narrower than
  // `min_pane` borrow from the largest ones; when even equal panes would be
  // below `min_pane`, all panes are equal.
  static std::vector<gfx::Rect> ComputePaneFrames(
      const gfx::Rect& content,
      SplitOrientation orientation,
      const std::vector<double>& fractions,
      size_t pane_count,
      int gap,
      int min_pane);

  // views::View:
  void Layout(PassKey) override;
  bool GetDropFormats(
      int* formats,
      std::set<ui::ClipboardFormatType>* format_types) override;
  bool CanDrop(const ui::OSExchangeData& data) override;
  void OnDragEntered(const ui::DropTargetEvent& event) override;
  int OnDragUpdated(const ui::DropTargetEvent& event) override;
  void OnDragExited() override;
  views::View::DropCallback GetDropCallback(
      const ui::DropTargetEvent& event) override;

 private:
  friend class split_internal::SplitDividerView;
  friend class split_internal::SplitPaneView;

  // Divider callbacks.
  void BeginDividerDrag(size_t pair_index);
  void UpdateDividerDrag(size_t pair_index, int delta, bool equalize);
  void EndDividerDrag(size_t pair_index, bool commit);

  // Pane callbacks.
  void OnPaneCommand(const ItemID& tab_id,
                     PaneCommand command,
                     views::View* anchor);
  void OnPaneFocused(const ItemID& tab_id);
  void OnEmptyPaneOpenCommandBar(const ItemID& tab_id);
  void OnPaneChromeDragSwap(const ItemID& source_tab_id,
                            const gfx::Point& point_in_container,
                            bool finished);
  void PerformDrop(std::optional<ItemID> dragged_tab_id,
                   GURL dragged_url,
                   SplitDropZone zone,
                   std::optional<size_t> target_pane_index,
                   const ui::DropTargetEvent& event,
                   ui::mojom::DragOperation& output_drag_op,
                   std::unique_ptr<ui::LayerTreeOwner> drag_image_layer_owner);

  void ApplyFrames(const std::vector<gfx::Rect>& frames);
  void SyncPaneShadows();
  void SyncDividers();
  void ReorderSplitChildren();
  bool EffectiveDarkContent() const;
  void UpdateDropOverlay();
  bool is_split() const { return presentation_.split_id.has_value(); }
  split_internal::SplitPaneView* FindPane(const ItemID& tab_id);
  std::optional<size_t> FindPaneIndex(const ItemID& tab_id) const;
  std::optional<size_t> PaneIndexAtPoint(const gfx::Point& point) const;

  raw_ptr<OpenSplitContainerDelegate> delegate_;
  SplitPresentation presentation_;
  std::optional<bool> dark_content_override_;
  std::vector<raw_ptr<split_internal::SplitPaneShadowView>> pane_shadows_;
  std::vector<raw_ptr<split_internal::SplitPaneView>> panes_;
  std::vector<raw_ptr<split_internal::SplitDividerView>> dividers_;
  raw_ptr<split_internal::SplitDropOverlayView> drop_overlay_ = nullptr;
  std::optional<SplitDropZone> drop_zone_preview_;
  std::optional<size_t> drop_target_pane_index_;
  std::optional<SkColor> drop_overlay_accent_;
  std::optional<ItemID> dnd_tab_id_;
  GURL dnd_url_;
  std::vector<double> live_fractions_;
  // Drag state.
  std::vector<gfx::Rect> drag_initial_frames_;
  std::vector<gfx::Rect> drag_current_frames_;
  base::WeakPtrFactory<OpenSplitContainerView> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_SPLIT_CONTAINER_VIEW_H_
