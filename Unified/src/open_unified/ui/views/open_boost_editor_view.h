// Copyright 2026 The Open Authors. All rights reserved.
//
// OpenBoostEditorView: the floating Boost editor panel that sits over the
// right edge of the live page (macOS BoostEditorPanel / BoostEditorView,
// Packages/OpenKit/Sources/OpenSiteControl/).
//
// Sources: BoostEditorMetrics / BoostEditorColors in
// Packages/OpenKit/Sources/OpenDesign/SiteControlTokens.swift (Arc 1.172
// capture S2 10/0030, 10/0071), BoostColorWheel in OpenBoosts/Boost.swift,
// the font list in OpenSiteControl/BoostEditorViews.swift, and the frames
// docs/sitecontrol/step-4/editor-{color,advanced,zap-on,zap-count,
// name-menu}-light@2x.png.
//
// Simple mode (183 x 588 pt, radius 12):
//   header 40 (#F5F5F7, hairline): Close (circle x), name + chevron (the
//     Boost menu: rename, shuffle, on/off, Zap undo/clear, reset, delete,
//     share, all Boosts), Undo (last editor change);
//   color pad 147 x 147 at (18, 58): hue ring + dotted plate + two knobs;
//   color buttons at y 220: Invert lightness, Advanced (Contrast,
//     Brightness, Original Saturation card), No color (reset color);
//   font card 147 x 120 at (18, 273): 5 x 4 "Aa" cells (System + 19
//     families; "Custom Font..." in the Boost menu);
//   Size (cycles 100 > 110 > 125 > 150 > 90 %, right-click lists every
//     size 75-200 %) and Case (cycles Original > Aa > AA > aa);
//   Zap row (dark #333333 while armed; stored count at the right): while
//     armed an extra row adds Undo Last Zap and Clear All (Open addition,
//     the panel grows by 44 pt);
//   Code row: switches to code mode.
// Code mode (480 x 588): Back, CSS / JS segments, a monospace editor, and a
//   bottom bar with Reset and Apply. CSS previews live and saves 150 ms
//   after typing stops (cssSaveDelay); JavaScript saves and runs on Apply
//   only (a half-typed script never runs).
//
// Dark mode colors are an Open choice (no Arc dark capture of the editor
// exists in docs/sitecontrol/step-4); light colors are measured.
//
// Live preview: every drag event of the color pad and sliders calls
// `on_live_preview` (the embedder forwards it to
// OpenBoostController::PreviewBoost, one isolated-world script, no store
// round trip); releasing the pointer, and every discrete change, calls
// `on_commit_boost`.

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_BOOST_EDITOR_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_BOOST_EDITOR_VIEW_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/timer/timer.h"
#include "open_unified/browser/open_boost_controller.h"
#include "open_unified/core/model/open_types.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/font_list.h"
#include "ui/gfx/geometry/point_f.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/menus/simple_menu_model.h"
#include "ui/views/controls/textfield/textfield_controller.h"
#include "ui/views/view.h"

namespace views {
class MenuRunner;
class Textarea;
class Textfield;
class Widget;
}  // namespace views

namespace open_unified {

namespace secondary {
class OverlayWidgetHost;
class PaintedButton;
}  // namespace secondary

// BoostEditorMetrics (SiteControlTokens.swift), editor-window points.
namespace boost_editor_metrics {
inline constexpr int kWidth = 183;
inline constexpr int kHeight = 588;
inline constexpr int kCodeWidth = 480;
inline constexpr int kCodeHeight = 588;
inline constexpr int kCornerRadius = 12;
inline constexpr int kHeaderHeight = 40;
inline constexpr int kInset = 18;
// Offset of the panel from the top of the page area, and the margin to the
// page's right edge (BoostEditorMetrics.topOffset / screenMargin).
inline constexpr int kTopOffset = 160;
inline constexpr int kScreenMargin = 8;
// Transparent margin around the panel for its drop shadow (Open choice).
inline constexpr int kShadowMargin = 14;
inline constexpr gfx::Rect kDone{0, 0, 40, 40};
inline constexpr gfx::Rect kName{46, 8, 91, 24};
inline constexpr gfx::Rect kUndo{143, 0, 40, 40};
inline constexpr gfx::Rect kRing{18, 58, 147, 147};
inline constexpr int kPlateInset = 7;
inline constexpr float kRingRadius = 20.f;
inline constexpr float kPlateRadius = 13.5f;
inline constexpr float kPadRadius = 66.5f;
inline constexpr float kDotPitch = 4.f;
inline constexpr float kDotSize = 1.f;
inline constexpr float kPrimaryDisc = 30.f;
inline constexpr float kPrimaryDragDisc = 38.f;
inline constexpr float kKnobRing = 2.f;
inline constexpr float kSecondaryDisc = 19.f;
inline constexpr float kSecondaryOffsetDegrees = 45.f;
inline constexpr float kDefaultKnobRadius = 40.f;
inline constexpr float kGuideWidth = 2.f;
inline constexpr gfx::Rect kColorButtons[3] = {
    {18, 220, 42, 38}, {70, 220, 43, 38}, {123, 220, 42, 38}};
inline constexpr float kButtonRadius = 9.f;
inline constexpr gfx::Rect kFontCard{18, 273, 147, 120};
inline constexpr float kFontCardRadius = 11.f;
inline constexpr int kFontColumns[5] = {23, 51, 79, 106, 134};
inline constexpr int kFontRows[4] = {281, 307, 333, 359};
inline constexpr int kFontCell = 26;
inline constexpr gfx::Rect kSize{18, 408, 70, 38};
inline constexpr gfx::Rect kCase{96, 408, 69, 38};
inline constexpr gfx::Rect kZap{18, 461, 147, 38};
inline constexpr gfx::Rect kCode{18, 514, 147, 38};
inline constexpr int kRowLabelInset = 12;
inline constexpr int kRowGlyphTrailingInset = 15;
// Open addition: the armed-Zap tools row under the Zap row.
inline constexpr int kZapToolsHeight = 44;
inline constexpr gfx::Rect kZapUndo{18, 507, 70, 30};
inline constexpr gfx::Rect kZapClear{96, 507, 69, 30};
// The advanced card (Arc draws a 250 pt popover at x -34; Open keeps it
// inside the panel so the overlay widget stays 183 pt wide).
inline constexpr gfx::Rect kAdvancedCard{6, 266, 171, 214};
inline constexpr int kAdvancedLabelY[3] = {299, 361, 423};
inline constexpr int kAdvancedSliderY[3] = {318, 380, 442};
inline constexpr int kSliderWidth = 147;
inline constexpr int kSliderHeight = 16;
inline constexpr int kBannerHeight = 28;
// Code mode.
inline constexpr gfx::Rect kBack{10, 9, 60, 23};
inline constexpr int kSegmentWidth = 50;
inline constexpr int kSegmentHeight = 24;
inline constexpr int kSegmentTop = 8;
inline constexpr float kSegmentRadius = 6.f;
inline constexpr int kCodeBottomBar = 70;
inline constexpr int kCodeButton = 38;
inline constexpr int kCodeBarInset = 15;
inline constexpr int kCodeBarTop = 17;
inline constexpr int kCodeBarGap = 10;
inline constexpr int kCodeNoticeHeight = 28;
inline constexpr int kCodeFont = 12;
inline constexpr int kCodeInsetX = 8;
inline constexpr int kCodeInsetY = 6;
inline constexpr int kCssSaveDelayMs = 150;
}  // namespace boost_editor_metrics

// The editor's color inputs (macOS BoostColorWheel). Runtime filters are
// derived from it; Unified's Boost stores only the derived filter, so
// FromColor() recovers an equivalent wheel (exact round trip of the
// filter, knob placement may differ from the session that made it).
struct BoostWheelState {
  // Degrees, 0 at 3 o'clock, increasing clockwise on screen.
  double hue = 0.0;
  // 0 (center) ... 1 (pad rim).
  double intensity = 0.0;
  bool invert = false;
  double brightness = 1.0;           // 0.5 ... 1.5
  double contrast = 1.0;             // 0.5 ... 1.5
  double original_saturation = 1.0;  // 0 ... 2

  bool IsIdentity() const;
  // BoostColorWheel.adjustment: hue-rotate(intensity * delta (+180 when
  // inverted)), saturate(original * (1 + 0.5 * intensity)), brightness,
  // contrast, invert.
  BoostColorAdjustment ToColor() const;
  static BoostWheelState FromColor(const BoostColorAdjustment& color);
};

// One cell of the font card.
struct BoostEditorFont {
  std::u16string name;
  // Stored in Boost::font_family (a CSS font-family list); empty = System
  // (no font override).
  std::string css;
  // The family used to draw the "Aa" sample.
  std::string family;
};
// System + the 19 families of BoostEditorFonts.available, in grid order.
const std::vector<BoostEditorFont>& BoostEditorFonts();

// The 2D hue / intensity pad: a hue ring around a dotted plate with the
// primary knob (dragged) and its secondary companion at +45 degrees.
// Arrow keys move the knob (Left/Right: hue, Up/Down: intensity).
class BoostColorWheelView : public views::View {
  METADATA_HEADER(BoostColorWheelView, views::View)

 public:
  // `dragging` is true for every event of a drag except the release.
  using ChangedCallback =
      base::RepeatingCallback<void(const BoostWheelState& state,
                                   bool dragging)>;

  explicit BoostColorWheelView(ChangedCallback on_changed);
  BoostColorWheelView(const BoostColorWheelView&) = delete;
  BoostColorWheelView& operator=(const BoostColorWheelView&) = delete;
  ~BoostColorWheelView() override;

  void SetState(const BoostWheelState& state);
  const BoostWheelState& state() const { return state_; }
  void SetDark(bool dark);
  bool dragging() const { return dragging_; }

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void OnPaint(gfx::Canvas* canvas) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  bool OnMouseDragged(const ui::MouseEvent& event) override;
  void OnMouseReleased(const ui::MouseEvent& event) override;
  void OnMouseCaptureLost() override;
  bool OnKeyPressed(const ui::KeyEvent& event) override;

 private:
  gfx::PointF Center() const;
  gfx::PointF KnobCenter(float angle_degrees) const;
  void UpdateFromPoint(const gfx::Point& point, bool dragging);
  void Notify(bool dragging);

  ChangedCallback on_changed_;
  BoostWheelState state_;
  bool dark_ = false;
  bool dragging_ = false;
};

class BoostEditorSliderView;
class BoostEditorConfirmView;

class OpenBoostEditorView : public views::View,
                            public views::TextfieldController,
                            public ui::SimpleMenuModel::Delegate {
  METADATA_HEADER(OpenBoostEditorView, views::View)

 public:
  struct Callbacks {
    // Draft changed (every drag event, every keystroke of CSS).
    base::RepeatingCallback<void(const Boost&)> on_live_preview;
    // Save the Boost (pointer released, discrete edits, CSS debounce,
    // JavaScript Apply, rename).
    base::RepeatingCallback<void(const Boost&)> on_commit_boost;
    // Delete confirmed in the panel. The embedder closes the editor.
    base::RepeatingCallback<void(const std::string& boost_id)>
        on_delete_boost;
    // The Zap row: arm (true) or end (false) Zap for the Boost.
    base::RepeatingCallback<void(bool armed, const std::string& boost_id)>
        on_toggle_zap;
    base::RepeatingCallback<void(const std::string& boost_id)> on_undo_zap;
    base::RepeatingCallback<void(const std::string& boost_id)> on_clear_zaps;
    // "Share Boost..." (export JSON / share sheet; the embedder decides).
    base::RepeatingCallback<void(const Boost&)> on_share_boost;
    // "All Boosts..." (open the Boosts manager). Optional.
    base::RepeatingClosure on_show_all_boosts;
    // Close button, Escape in simple mode.
    base::RepeatingClosure on_close;
  };

  enum class Mode { kSimple, kCode };
  enum class CodeTab { kCss, kJs };

  OpenBoostEditorView(Callbacks callbacks,
                      const Boost& boost,
                      bool zap_armed,
                      bool dark);
  OpenBoostEditorView(const OpenBoostEditorView&) = delete;
  OpenBoostEditorView& operator=(const OpenBoostEditorView&) = delete;
  ~OpenBoostEditorView() override;

  // External update (store reload, sync, Zap edits). Ignored for the
  // fields the user is editing right now (a drag, rename, unsaved code).
  void SetBoost(const Boost& boost);
  void SetZapState(bool armed, int zap_count);
  void SetDark(bool dark);
  // advanced.enableBoosts: off shows the "Boosts are off" banner.
  void SetBoostsGloballyEnabled(bool enabled);
  // A short message in the banner row (Zap could not start, ...), cleared
  // after a few seconds.
  void ShowNotice(const std::u16string& text);
  void SetMode(Mode mode);

  const Boost& boost() const { return boost_; }
  bool zap_armed() const { return zap_armed_; }
  int zap_count() const { return zap_count_; }
  Mode mode() const { return mode_; }
  bool dark() const { return dark_; }
  // The panel rect inside this view (the rest is shadow margin).
  gfx::Rect PanelBounds() const;

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;
  bool AcceleratorPressed(const ui::Accelerator& accelerator) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;

  // views::TextfieldController:
  void ContentsChanged(views::Textfield* sender,
                       const std::u16string& new_contents) override;
  bool HandleKeyEvent(views::Textfield* sender,
                      const ui::KeyEvent& key_event) override;

  // ui::SimpleMenuModel::Delegate:
  void ExecuteCommand(int command_id, int event_flags) override;
  bool IsCommandIdEnabled(int command_id) const override;
  bool IsCommandIdChecked(int command_id) const override;

 private:
  enum class TextPrompt { kNone, kRename, kCustomFont };

  struct Palette {
    SkColor header;
    SkColor hairline;
    SkColor body;
    SkColor button;
    SkColor button_hover;
    SkColor button_pressed;
    SkColor button_on;
    SkColor advanced_on;
    SkColor on_glyph;
    SkColor label;
    SkColor title;
    SkColor header_glyph;
    SkColor chevron;
    SkColor disabled_glyph;
    SkColor row_label;
    SkColor font_card;
    SkColor font_glyph;
    SkColor font_selected;
    SkColor font_selected_glyph;
    SkColor card;
    SkColor shadow;
    SkColor warning;
    SkColor segment_selected;
    SkColor segment_idle;
    SkColor code_background;
    SkColor primary_fill;
    SkColor primary_text;
  };
  static Palette PaletteFor(bool dark);

  // --- Building ---
  secondary::PaintedButton* AddButton(
      const std::u16string& name,
      base::RepeatingCallback<void(gfx::Canvas*, const gfx::Rect&, bool)>
          painter,
      base::RepeatingClosure on_press);
  void BuildSimpleControls();
  void BuildCodeControls();
  void UpdateVisibility();
  void UpdateTooltips();

  // --- Edits ---
  // Applies |updated| as the new draft. |commit|: save now. |undoable|:
  // push the previous draft on the editor's Undo stack.
  void ApplyDraft(Boost updated, bool commit, bool undoable);
  void Preview();
  void Commit();
  void PushUndo();
  void Undo();
  void OnWheelChanged(const BoostWheelState& state, bool dragging);
  void OnSliderChanged(int index, double value, bool dragging);
  void SetWheel(const BoostWheelState& state, bool dragging);
  void ToggleInvert();
  void ToggleAdvanced();
  void ResetColor();
  void SelectFont(size_t index);
  void CycleTextSize(bool backwards);
  void CycleTextCase(bool backwards);
  void ShowSizeMenu();
  void ToggleZap();
  void Shuffle();
  void ResetAll();
  void ShowBoostMenu();
  void BeginPrompt(TextPrompt prompt);
  void EndPrompt(bool commit);
  void ShowDeleteConfirm(bool show);
  void SelectCodeTab(CodeTab tab);
  void ApplyCode();
  void ResetCode();
  void CommitCss();

  // --- Painting ---
  void PaintHeaderName(gfx::Canvas* canvas, const gfx::Rect& bounds,
                       bool hovered);
  void PaintColorButton(int index, gfx::Canvas* canvas,
                        const gfx::Rect& bounds, bool hovered);
  void PaintFontCell(size_t index, gfx::Canvas* canvas,
                     const gfx::Rect& bounds, bool hovered);
  void PaintTextButton(const std::u16string& label, bool on,
                       gfx::Canvas* canvas, const gfx::Rect& bounds,
                       bool hovered);
  void PaintZapRow(gfx::Canvas* canvas, const gfx::Rect& bounds,
                   bool hovered);
  void PaintCodeRow(gfx::Canvas* canvas, const gfx::Rect& bounds,
                    bool hovered);
  void PaintSegment(CodeTab tab, gfx::Canvas* canvas,
                    const gfx::Rect& bounds, bool hovered);
  void PaintCodeButton(bool primary, const std::u16string& label,
                       gfx::Canvas* canvas, const gfx::Rect& bounds,
                       bool hovered);
  void PaintPanel(gfx::Canvas* canvas);

  // Panel-relative rect -> view rect (adds the shadow margin and the
  // banner / Zap tools shift for rows below them).
  gfx::Rect P(const gfx::Rect& panel_rect) const;
  int BannerShift() const;
  int ZapToolsShift() const;
  int FontIndex() const;
  int TextSizeIndex() const;
  int TextCaseIndex() const;

  Callbacks callbacks_;
  Boost boost_;
  BoostWheelState wheel_;
  Palette palette_;
  bool dark_ = false;
  bool zap_armed_ = false;
  int zap_count_ = 0;
  bool global_enabled_ = true;
  std::u16string notice_;
  base::OneShotTimer notice_timer_;
  bool advanced_open_ = false;
  bool confirming_delete_ = false;
  bool interacting_ = false;  // A drag of the pad or a slider.
  Mode mode_ = Mode::kSimple;
  CodeTab code_tab_ = CodeTab::kCss;
  TextPrompt prompt_ = TextPrompt::kNone;
  std::vector<Boost> undo_stack_;
  // Code edited but not yet saved (JS waits for Apply).
  bool css_dirty_ = false;
  bool js_dirty_ = false;
  std::u16string pending_js_;
  base::OneShotTimer css_save_timer_;
  std::vector<gfx::FontList> font_samples_;

  // Simple mode.
  raw_ptr<secondary::PaintedButton> close_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> name_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> undo_button_ = nullptr;
  raw_ptr<BoostColorWheelView> wheel_view_ = nullptr;
  std::vector<raw_ptr<secondary::PaintedButton>> color_buttons_;
  std::vector<raw_ptr<secondary::PaintedButton>> font_cells_;
  raw_ptr<secondary::PaintedButton> size_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> case_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> zap_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> zap_undo_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> zap_clear_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> code_button_ = nullptr;
  raw_ptr<views::View> advanced_scrim_ = nullptr;
  raw_ptr<views::View> advanced_card_ = nullptr;
  std::vector<raw_ptr<BoostEditorSliderView>> sliders_;
  raw_ptr<views::Textfield> prompt_field_ = nullptr;
  raw_ptr<BoostEditorConfirmView> confirm_view_ = nullptr;

  // Code mode.
  raw_ptr<secondary::PaintedButton> back_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> css_segment_ = nullptr;
  raw_ptr<secondary::PaintedButton> js_segment_ = nullptr;
  raw_ptr<views::Textarea> code_area_ = nullptr;
  raw_ptr<secondary::PaintedButton> code_reset_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> code_apply_button_ = nullptr;

  std::unique_ptr<ui::SimpleMenuModel> menu_model_;
  std::unique_ptr<views::MenuRunner> menu_runner_;
  base::WeakPtrFactory<OpenBoostEditorView> weak_factory_{this};
};

// Hosts an OpenBoostEditorView in a frameless, translucent child widget of
// the browser window (secondary::OverlayWidgetHost, activatable), pinned to
// the top-right of the page area.
class OpenBoostEditorHost {
 public:
  OpenBoostEditorHost();
  OpenBoostEditorHost(const OpenBoostEditorHost&) = delete;
  OpenBoostEditorHost& operator=(const OpenBoostEditorHost&) = delete;
  ~OpenBoostEditorHost();

  // Opens (or replaces) the editor for |boost|. |page_bounds_in_screen| is
  // the page (web contents) area; the panel sits kScreenMargin from its
  // right edge and kTopOffset below its top (less when the page is short).
  // `on_close` in |callbacks| also hides the panel.
  OpenBoostEditorView* ShowForBoost(views::Widget* parent_widget,
                                    const gfx::Rect& page_bounds_in_screen,
                                    const Boost& boost,
                                    bool zap_armed,
                                    bool dark,
                                    OpenBoostEditorView::Callbacks callbacks);
  // Re-anchors after a window resize or sidebar toggle.
  void UpdatePageBounds(const gfx::Rect& page_bounds_in_screen);
  void Hide();
  bool IsVisible() const;
  OpenBoostEditorView* view() { return view_; }

 private:
  void ApplyAnchor();

  std::unique_ptr<secondary::OverlayWidgetHost> host_;
  raw_ptr<views::Widget> parent_ = nullptr;
  raw_ptr<OpenBoostEditorView> view_ = nullptr;
  gfx::Rect page_bounds_in_screen_;
  base::WeakPtrFactory<OpenBoostEditorHost> weak_factory_{this};
};

// Binds the editor to OpenBoostController for one tab: previews, saves,
// deletes and Zap go to the controller; controller pushes (Boost reloads,
// Zap state) update the panel. Closing ends the preview and any Zap.
//
//   session_ = std::make_unique<OpenBoostEditorSession>(
//       service->boost_controller(), profile_id, tab_id);
//   session_->Show(GetWidget(), page_bounds_in_screen, boost, dark);
class OpenBoostEditorSession : public OpenBoostController::Observer {
 public:
  OpenBoostEditorSession(OpenBoostController* controller,
                         ProfileID profile_id,
                         ItemID tab_id);
  OpenBoostEditorSession(const OpenBoostEditorSession&) = delete;
  OpenBoostEditorSession& operator=(const OpenBoostEditorSession&) = delete;
  ~OpenBoostEditorSession() override;

  // Optional embedder hooks.
  void set_on_share(base::RepeatingCallback<void(const Boost&)> on_share) {
    on_share_ = std::move(on_share);
  }
  void set_on_show_all(base::RepeatingClosure on_show_all) {
    on_show_all_ = std::move(on_show_all);
  }
  // Runs after the panel closed (Close, Escape, delete).
  void set_on_closed(base::OnceClosure on_closed) {
    on_closed_ = std::move(on_closed);
  }

  // Opens the editor for |boost| (a new Boost may have an empty id: the
  // first commit creates it).
  void Show(views::Widget* parent_widget,
            const gfx::Rect& page_bounds_in_screen,
            const Boost& boost,
            bool dark);
  void UpdatePageBounds(const gfx::Rect& page_bounds_in_screen);
  // Ends the preview and any Zap, then hides the panel.
  void Close();
  bool IsVisible() const { return host_.IsVisible(); }
  const ItemID& tab_id() const { return tab_id_; }
  OpenBoostEditorView* view() { return host_.view(); }

  // OpenBoostController::Observer:
  void OnBoostsChanged(const ProfileID& profile_id) override;
  void OnZapStateChanged(bool armed,
                         const std::string& boost_id,
                         int zap_count) override;

 private:
  void Commit(const Boost& boost);

  raw_ptr<OpenBoostController> controller_;
  ProfileID profile_id_;
  ItemID tab_id_;
  std::string boost_id_;
  OpenBoostEditorHost host_;
  base::RepeatingCallback<void(const Boost&)> on_share_;
  base::RepeatingClosure on_show_all_;
  base::OnceClosure on_closed_;
  bool closing_ = false;
  // The Boost reached the controller's cache once (a later absence means
  // it was deleted elsewhere: the editor closes).
  bool seen_in_store_ = false;
  base::ScopedObservation<OpenBoostController, OpenBoostController::Observer>
      observation_{this};
  base::WeakPtrFactory<OpenBoostEditorSession> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_BOOST_EDITOR_VIEW_H_
