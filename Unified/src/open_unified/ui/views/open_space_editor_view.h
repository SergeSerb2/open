// Copyright 2026 The Open Authors. All rights reserved.
//
// Space theme editor and Space creation popovers (Views port of
// Packages/OpenKit/Sources/OpenSpaceEditor).
//
// Sources (Swift, this repo):
//   ThemeEditorPanel.swift / ThemeEditorController.swift   -> OpenSpaceThemeEditorView
//   ThemeEditorState.swift                                 -> space_editor::ThemeEditorState
//   ColorPadView.swift + OpenDesign/ColorPad.swift         -> space_editor::ColorPadView
//   NoiseDialView.swift                                    -> space_editor::NoiseDialView
//   SineSliderView.swift                                   -> space_editor::SineSliderView
//   PresetStripView.swift + OpenDesign/SpaceStylePresets   -> space_editor::PresetStripView
//   AppearanceModeBar.swift (ThemeEditorButton)            -> space_editor::AppearanceModeBar
//   IconPickerView.swift / IconPickerController.swift      -> OpenSpaceIconPickerView
//   SpaceCreationView.swift / SpaceCreationController      -> OpenSpaceCreationView
//   OpenDesign/ThemeEditorTokens.swift                     -> space_editor::metrics / colors
//
// The editor edits `SpaceTheme::style` (SpaceStyle): one key color plus a
// 1..3 color harmony (`color_count`, `wheel`), `appearance`, `noise_factor`
// (+ `texture`) and `intensity_factor`. The pad's color dots are the
// harmony's knobs: the first (44 pt) is the draggable key, the others
// (27 pt) follow the harmony, exactly like Swift. "+" adds a color (2nd, 3rd;
// 1 -> 2 switches the wheel to complementary), "-" removes one (1 -> none =
// the default theme). Double-clicking a secondary dot removes a color too.
//
// Material: Arc/Swift use a behind-window NSVisualEffectView. Views has no
// cheap backdrop blur, so the panel body is solid (Open choice, same as
// OpenSiteControlBubble); callers may pass a themed `panel_color`.
//
// Popovers are views::BubbleDialogDelegate bubbles (Chromium 156 keeps
// BubbleDialogDelegateView's constructors private, so this uses the public
// BubbleDialogDelegate + contents view pattern). A bubble anchored to a
// browser widget keeps that widget painting as active, so the browser window
// never loses its active look while the editor is key. They close on
// deactivate and on Esc.

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_SPACE_EDITOR_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_SPACE_EDITOR_VIEW_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/timer/timer.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/ui/design/open_theme_math.h"
#include "open_unified/ui/design/open_theme_shader.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/animation/animation_delegate.h"
#include "ui/gfx/animation/slide_animation.h"
#include "ui/gfx/geometry/point_f.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/menus/simple_menu_model.h"
#include "ui/views/bubble/bubble_border.h"
#include "ui/views/controls/button/button.h"
#include "ui/views/controls/textfield/textfield_controller.h"
#include "ui/views/view.h"
#include "ui/views/widget/widget.h"

namespace views {
class BubbleDialogDelegate;
class MenuRunner;
class Textfield;
}  // namespace views

namespace open_unified {

namespace space_editor {

// ThemeEditorMetrics (content coordinates; the Swift panel's transparent
// 13 pt outer band is replaced by the bubble border's own shadow).
namespace metrics {
inline constexpr int kContentWidth = 356;
inline constexpr int kThemeHeight = 508;
inline constexpr int kCornerRadius = 20;
inline constexpr gfx::Rect kPad{8, 8, 340, 340};
inline constexpr float kPadRadius = 170;
inline constexpr float kPadCornerRadius = 4;
inline constexpr float kPrimaryKnob = 44;
inline constexpr float kSecondaryKnob = 27;
inline constexpr float kPrimaryRing = 5;
inline constexpr float kSecondaryRing = 3;
inline constexpr float kDotPitch = 4.25f;
inline constexpr float kKnobDragScale = 1.136f;
inline constexpr float kKnobHoverScale = 1.09f;
inline constexpr float kSecondaryActiveScale = 30.0f / 27.0f;
inline constexpr gfx::Rect kModeBar{122, 32, 112, 32};
inline constexpr gfx::Rect kRemove{142, 300, 32, 32};
inline constexpr gfx::Rect kAdd{182, 300, 32, 32};
inline constexpr gfx::Rect kPresetStrip{0, 364, 356, 32};
inline constexpr gfx::Rect kPrevious{9, 0, 32, 32};    // in the strip
inline constexpr gfx::Rect kNext{315, 0, 32, 32};      // in the strip
inline constexpr gfx::Rect kSwatches{48, 0, 260, 32};  // in the strip
inline constexpr float kSwatchPitch = 29.5f;
inline constexpr float kSwatchPage = 265.5f;
inline constexpr int kSwatch = 24;
// The Swift slider frame is {18, 424, 224, 56}; its thumb overflows by up to
// 1.6 pt, so the Views frame grows by 4 pt above and below (art offset +4).
inline constexpr gfx::Rect kIntensity{18, 420, 224, 64};
inline constexpr float kIntensityArtOffset = 4;
inline constexpr float kIntensityThumbStart = 7.8f;
inline constexpr float kIntensityTravel = 208.4f;
inline constexpr gfx::Rect kNoise{258, 412, 84, 80};
inline constexpr gfx::PointF kNoiseCenter{40, 40};
inline constexpr float kNoiseRadius = 32;
inline constexpr float kNoiseTickWidth = 8;
inline constexpr float kNoiseTickHeight = 16;
inline constexpr float kNoiseButton = 40;
// Open addition below the Swift panel: Theme / Space tabs, Undo, Reset, Done.
inline constexpr int kFooterHeight = 44;
inline constexpr int kPanelHeight = kThemeHeight + kFooterHeight;
// Icon picker (IconPickerView.size 246 x 300, 7 columns of 28 pt cells).
inline constexpr int kIconPickerWidth = 246;
inline constexpr int kIconPickerHeight = 300;
inline constexpr int kIconCell = 28;
inline constexpr int kIconSpacing = 5;
// Space creation card (SpaceCreationView, full width class).
inline constexpr int kCreationWidth = 280;
inline constexpr int kCreationCornerRadius = 16;
// Motion (Motion.swift): editor fade 0.12 s, knob/thumb scale 0.12 s.
inline constexpr int kScaleMs = 120;
inline constexpr int kPresetPageMs = 250;
}  // namespace metrics

// ThemeEditorColors, resolved for the panel's content appearance.
struct EditorColors {
  SkColor panel;
  SkColor pad_fill;
  SkColor dot;
  SkColor glyph;
  SkColor glyph_selected;
  SkColor selected_plate;
  SkColor hover_plate;
  SkColor secondary_text;
  SkColor primary_text;
  SkColor track_fill;
  SkColor wave_active;
  SkColor wave_inactive;
  SkColor thumb;
  SkColor dot_unlit;
  SkColor dot_lit;
  SkColor card_fill;
  SkColor separator;
  SkColor focus_ring;
  SkColor shadow;  // knob / thumb drop shadow color (alpha included)
  bool dark = true;

  static EditorColors For(bool dark,
                          std::optional<SkColor> panel = std::nullopt);
};
inline constexpr float kDisabledGlyphAlpha = 0.32f;

// SpaceStylePresets: 5 pages x 9 swatches (brand, brand 3-color gradient,
// pastel, drab, greyscale).
inline constexpr int kPresetPageCount = 5;
inline constexpr int kSwatchesPerPage = 9;
struct ThemePreset {
  std::u16string name;
  SpaceStyle style;
};
const std::vector<ThemePreset>& ThemePresets();

// SpaceStyle.seed(from:): the stored editor style, else the first legacy
// light stop as a 1-color key, else none (default theme).
std::optional<SpaceStyle> SeedStyle(const SpaceTheme& theme);
// SpaceTheme(style:): a theme that holds only `style` (none = default).
SpaceTheme ThemeFromStyle(const std::optional<SpaceStyle>& style);
// A new Swift-default editor style (1 color, intensity 0.8, no noise).
SpaceStyle NewStyle(const RGBAColor& key, ThemeAppearance appearance);

// Values only (ThemeEditorState.swift). Views paint it; the editor view
// owns preview, commit and undo.
class ThemeEditorState {
 public:
  static constexpr double kNoiseInputEpsilon = 1e-6;

  explicit ThemeEditorState(std::optional<SpaceStyle> style = std::nullopt);
  ThemeEditorState(const ThemeEditorState&);
  ThemeEditorState& operator=(const ThemeEditorState&);
  ~ThemeEditorState();

  const std::optional<SpaceStyle>& style() const { return style_; }
  ThemeAppearance appearance() const;
  bool gesture_in_progress() const { return gesture_; }
  int preset_page() const { return preset_page_; }
  void set_preset_page(int page);

  // Knob positions on the unit disc (x right, y down) and fills, key first.
  struct Knob {
    gfx::PointF position;
    theme::P3 color;
  };
  std::vector<Knob> Knobs() const;
  std::optional<gfx::PointF> KeyKnob() const;

  // Actions (ThemeEditorAction). Each returns true when `style()` changed.
  bool DragKnob(const gfx::PointF& unit_point, bool relative);
  void BeginKeyboardGesture();
  void EndGesture();
  bool AddColor();
  bool RemoveColor();
  bool SetAppearance(ThemeAppearance mode);
  bool SelectPreset(size_t index);
  bool SetIntensity(double value, bool final);
  bool SetNoise(double value, bool final);
  bool CycleTexture();
  bool KeyboardHue(double degrees);
  bool KeyboardRadius(double delta);

 private:
  bool SetColorAt(const gfx::PointF& point);

  std::optional<SpaceStyle> style_;
  int preset_page_ = 0;
  bool gesture_ = false;
  double range_lo_ = 0.01;
  double range_hi_ = 0.97;
  double saturation_ = 1;
  ThemeAppearance empty_appearance_ = ThemeAppearance::kAutomatic;
  std::optional<gfx::PointF> start_knob_;
  std::optional<gfx::PointF> start_pointer_;
};

// The glyphs the editor uses. SF Symbols on macOS (glyphs::DrawSystemSymbol),
// Open's own Skia paths on Windows and Linux.
enum class EditorGlyph {
  kPlus,
  kMinus,
  kChevronLeft,
  kChevronRight,
  kChevronDown,
  kSparkles,
  kSun,
  kMoon,
  kUndo,
  kSmiley,
  kClose,
  kMagnifier,
};
void DrawEditorGlyph(gfx::Canvas* canvas,
                     EditorGlyph glyph,
                     const gfx::RectF& box,
                     SkColor color,
                     float point_size);

// ThemeEditorButton: a code-drawn 8 pt-radius plate plus one glyph or label.
class EditorButton : public views::Button {
  METADATA_HEADER(EditorButton, views::Button)

 public:
  EditorButton(PressedCallback callback,
               EditorGlyph glyph,
               float point_size,
               const std::u16string& accessible_name);
  // A text button (Reset, Done, Create Space, Cancel ...).
  EditorButton(PressedCallback callback, const std::u16string& label);
  EditorButton(const EditorButton&) = delete;
  EditorButton& operator=(const EditorButton&) = delete;
  ~EditorButton() override;

  void SetColors(const EditorColors& colors);
  void SetSelected(bool selected);
  bool selected() const { return selected_; }
  void SetGlyph(EditorGlyph glyph);
  void SetGlyphOffset(float dy) { glyph_offset_ = dy; SchedulePaint(); }
  // Filled (primary) style: `fill` plate, `text` color, always visible.
  void SetFilled(SkColor fill, SkColor text);
  void SetTextColor(SkColor text);
  void SetLabel(const std::u16string& label);
  void SetFontSize(int size, bool semibold);
  // Left-aligned label with a trailing chevron.down (popup buttons).
  void SetTrailingChevron(bool chevron);

  // views::Button:
  void PaintButtonContents(gfx::Canvas* canvas) override;

 private:
  std::optional<EditorGlyph> glyph_;
  float point_size_ = 16;
  float glyph_offset_ = 0;
  std::u16string label_;
  int font_size_ = 13;
  bool semibold_ = false;
  bool chevron_ = false;
  bool selected_ = false;
  std::optional<SkColor> filled_;
  std::optional<SkColor> text_;
  EditorColors colors_ = EditorColors::For(true);
};

// The 2-D color pad: 340 x 340 dotted plate, harmony knobs on a unit disc of
// radius 170 (hue = angle, lightness = radius within the editor range).
class ColorPadView : public views::View, public gfx::AnimationDelegate {
  METADATA_HEADER(ColorPadView, views::View)

 public:
  struct Callbacks {
    base::RepeatingCallback<void(const gfx::PointF& unit, bool relative)>
        on_drag;
    base::RepeatingClosure on_end_drag;
    base::RepeatingClosure on_begin_keyboard;
    base::RepeatingClosure on_end_keyboard;
    base::RepeatingCallback<void(double degrees)> on_keyboard_hue;
    base::RepeatingCallback<void(double delta)> on_keyboard_radius;
    // Double-click on a secondary knob.
    base::RepeatingClosure on_remove_color;
  };

  explicit ColorPadView(Callbacks callbacks);
  ColorPadView(const ColorPadView&) = delete;
  ColorPadView& operator=(const ColorPadView&) = delete;
  ~ColorPadView() override;

  void Apply(const ThemeEditorState& state, const EditorColors& colors);
  std::optional<gfx::RectF> PrimaryKnobFrame() const;
  void FinishKeyboardGesture();

  // views::View:
  void OnPaint(gfx::Canvas* canvas) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  bool OnMouseDragged(const ui::MouseEvent& event) override;
  void OnMouseReleased(const ui::MouseEvent& event) override;
  void OnMouseCaptureLost() override;
  void OnMouseMoved(const ui::MouseEvent& event) override;
  void OnMouseExited(const ui::MouseEvent& event) override;
  bool OnKeyPressed(const ui::KeyEvent& event) override;
  bool OnKeyReleased(const ui::KeyEvent& event) override;
  void OnBlur() override;

  // gfx::AnimationDelegate:
  void AnimationProgressed(const gfx::Animation* animation) override;

 private:
  gfx::PointF Unit(const gfx::PointF& p) const;
  gfx::PointF KnobCenter(const gfx::PointF& unit) const;
  bool OnPrimaryKnob(const gfx::PointF& p) const;
  void UpdateKnobScale();
  float CurrentScale() const;
  const gfx::ImageSkia& DotGrid(float scale);

  Callbacks callbacks_;
  std::vector<ThemeEditorState::Knob> knobs_;
  bool has_style_ = false;
  bool gesture_ = false;
  bool dragging_ = false;
  bool drag_relative_ = false;
  bool pointer_on_knob_ = false;
  bool keyboard_active_ = false;
  bool show_focus_ = false;  // keyboard focus only (Swift keyboardFocusOnly)
  int arrow_keys_down_ = 0;
  EditorColors colors_ = EditorColors::For(true);
  float scale_from_ = 1;
  float scale_to_ = 1;
  gfx::SlideAnimation scale_animation_{this};
  gfx::ImageSkia dot_grid_;
  SkColor dot_grid_color_ = SK_ColorTRANSPARENT;
  float dot_grid_scale_ = 0;
};

// Automatic / Light / Dark (sparkles, sun.max.fill, moon.stars.fill).
class AppearanceModeBar : public views::View {
  METADATA_HEADER(AppearanceModeBar, views::View)

 public:
  explicit AppearanceModeBar(
      base::RepeatingCallback<void(ThemeAppearance)> on_select);
  AppearanceModeBar(const AppearanceModeBar&) = delete;
  AppearanceModeBar& operator=(const AppearanceModeBar&) = delete;
  ~AppearanceModeBar() override;

  void Apply(ThemeAppearance mode, const EditorColors& colors);
  ThemeAppearance mode() const { return mode_; }

  // views::View:
  void Layout(PassKey) override;

 private:
  base::RepeatingCallback<void(ThemeAppearance)> on_select_;
  std::vector<raw_ptr<EditorButton>> buttons_;
  ThemeAppearance mode_ = ThemeAppearance::kAutomatic;
};

// Prev / 9 swatches (5 pages, sliding strip) / Next.
class PresetStripView : public views::View, public gfx::AnimationDelegate {
  METADATA_HEADER(PresetStripView, views::View)

 public:
  struct Callbacks {
    base::RepeatingCallback<void(size_t index)> on_select;
    base::RepeatingCallback<void(int page)> on_page;
  };
  explicit PresetStripView(Callbacks callbacks);
  PresetStripView(const PresetStripView&) = delete;
  PresetStripView& operator=(const PresetStripView&) = delete;
  ~PresetStripView() override;

  void Apply(int page, const EditorColors& colors);
  int page() const { return page_; }
  // Draws a 2 pt ring around this preset (creation card).
  void SetSelected(std::optional<size_t> index);
  // Compact (narrow card): no Previous / Next buttons, the viewport uses the
  // full width; page with the wheel, arrow keys or the owner's page dots.
  void SetCompact(bool compact);

  // views::View:
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  void OnMouseReleased(const ui::MouseEvent& event) override;
  void OnMouseMoved(const ui::MouseEvent& event) override;
  void OnMouseExited(const ui::MouseEvent& event) override;
  bool OnMouseWheel(const ui::MouseWheelEvent& event) override;
  bool OnKeyPressed(const ui::KeyEvent& event) override;
  void OnFocus() override;
  void OnBlur() override;

  // gfx::AnimationDelegate:
  void AnimationProgressed(const gfx::Animation* animation) override;

 private:
  std::optional<size_t> SwatchAt(const gfx::Point& p) const;
  gfx::RectF SwatchRect(size_t index) const;
  float StripOffset() const;

  Callbacks callbacks_;
  raw_ptr<EditorButton> previous_ = nullptr;
  raw_ptr<EditorButton> next_ = nullptr;
  int page_ = 0;
  float offset_from_ = 0;
  float offset_to_ = 0;
  gfx::SlideAnimation page_animation_{this};
  std::optional<size_t> hovered_;
  std::optional<size_t> pressed_;
  std::optional<size_t> focused_;  // keyboard focus within the page
  std::optional<size_t> selected_;
  bool compact_ = false;
  float device_scale_ = 1;
  float viewport_x_ = 48;
  float viewport_width_ = 260;
  float pitch_ = metrics::kSwatchPitch;
  float page_width_ = metrics::kSwatchPage;
  float scroll_amount_ = 0;
  EditorColors colors_ = EditorColors::For(true);
};

// Intensity: a sine wave whose amplitude follows the value, 4.5 pt stroke,
// active part left of the pill thumb.
class SineSliderView : public views::View {
  METADATA_HEADER(SineSliderView, views::View)

 public:
  explicit SineSliderView(
      base::RepeatingCallback<void(double value, bool final)> on_change);
  SineSliderView(const SineSliderView&) = delete;
  SineSliderView& operator=(const SineSliderView&) = delete;
  ~SineSliderView() override;

  void Apply(double value, bool enabled, const EditorColors& colors);
  gfx::RectF ThumbFrame() const;  // view coordinates

  // views::View:
  void OnPaint(gfx::Canvas* canvas) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  bool OnMouseDragged(const ui::MouseEvent& event) override;
  void OnMouseReleased(const ui::MouseEvent& event) override;
  void OnMouseCaptureLost() override;
  void OnMouseMoved(const ui::MouseEvent& event) override;
  void OnMouseExited(const ui::MouseEvent& event) override;
  bool OnMouseWheel(const ui::MouseWheelEvent& event) override;
  bool OnKeyPressed(const ui::KeyEvent& event) override;

 private:
  void Drag(const gfx::PointF& p, bool final);
  gfx::SizeF ThumbSize() const;

  base::RepeatingCallback<void(double, bool)> on_change_;
  double value_ = 0.8;
  bool enabled_ = true;
  bool hovered_ = false;
  bool pressed_ = false;
  EditorColors colors_ = EditorColors::For(true);
  // Ends a wheel gesture (one undo step) 300 ms after the last wheel event.
  base::OneShotTimer wheel_end_;
};

// Noise: 20 dots on a 32 pt ring, a rotating 8 x 16 tick, a 40 pt center
// button that cycles the texture (grain, sand, denim, tweed, none).
class NoiseDialView : public views::View {
  METADATA_HEADER(NoiseDialView, views::View)

 public:
  struct Callbacks {
    base::RepeatingCallback<void(double value, bool final)> on_change;
    base::RepeatingClosure on_cycle_texture;
  };
  explicit NoiseDialView(Callbacks callbacks);
  NoiseDialView(const NoiseDialView&) = delete;
  NoiseDialView& operator=(const NoiseDialView&) = delete;
  ~NoiseDialView() override;

  void Apply(double value,
             ThemeTexture texture,
             bool enabled,
             const EditorColors& colors);

  // views::View:
  void OnPaint(gfx::Canvas* canvas) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  bool OnMouseDragged(const ui::MouseEvent& event) override;
  void OnMouseReleased(const ui::MouseEvent& event) override;
  void OnMouseCaptureLost() override;
  bool OnMouseWheel(const ui::MouseWheelEvent& event) override;
  bool OnKeyPressed(const ui::KeyEvent& event) override;

 private:
  gfx::PointF RingPoint(double degrees) const;
  double AngleAt(const gfx::PointF& p) const;
  bool DotHidden(int index) const;
  bool InCenter(const gfx::PointF& p) const;

  Callbacks callbacks_;
  double value_ = 0;
  ThemeTexture texture_ = ThemeTexture::kGrain;
  bool enabled_ = true;
  bool pressed_ = false;
  bool center_pressed_ = false;
  EditorColors colors_ = EditorColors::For(true);
  base::OneShotTimer wheel_end_;
  // Texture preview in the center button (neutral gray + the texture).
  std::unique_ptr<theme::ThemePainter> preview_;
  std::optional<ThemeTexture> preview_texture_;
};

}  // namespace space_editor

// A profile the Space can use (SpaceProfileChoice).
struct SpaceProfileChoice {
  ProfileID id;
  std::u16string name;
  std::optional<SpaceIcon> icon;
};
std::vector<SpaceProfileChoice> SpaceProfileChoicesFrom(
    const std::vector<Profile>& profiles);

// ===========================================================================
// Icon picker: Emoji (curated, searchable, 8 categories) and Icons (the named
// Space icons, NamedSpaceIcons.order) plus "Remove icon".
// ===========================================================================
class OpenSpaceIconPickerView : public views::View,
                                public views::TextfieldController {
  METADATA_HEADER(OpenSpaceIconPickerView, views::View)

 public:
  enum class Page { kEmoji, kIcons };

  // `on_pick(nullopt)` is "Remove icon".
  OpenSpaceIconPickerView(
      std::optional<SpaceIcon> current,
      base::RepeatingCallback<void(const std::optional<SpaceIcon>&)> on_pick);
  OpenSpaceIconPickerView(const OpenSpaceIconPickerView&) = delete;
  OpenSpaceIconPickerView& operator=(const OpenSpaceIconPickerView&) = delete;
  ~OpenSpaceIconPickerView() override;

  void SetCurrent(std::optional<SpaceIcon> current);
  void SetColors(const space_editor::EditorColors& colors);
  void SelectPage(Page page);
  Page page() const { return page_; }
  // Cells per row at the current width (7 at the Swift 246 pt width).
  int Columns() const;

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  void OnMouseReleased(const ui::MouseEvent& event) override;
  void OnMouseMoved(const ui::MouseEvent& event) override;
  void OnMouseExited(const ui::MouseEvent& event) override;
  bool OnMouseWheel(const ui::MouseWheelEvent& event) override;
  bool OnKeyPressed(const ui::KeyEvent& event) override;
  void OnFocus() override;
  void OnBlur() override;

  // views::TextfieldController:
  void ContentsChanged(views::Textfield* sender,
                       const std::u16string& new_contents) override;
  bool HandleKeyEvent(views::Textfield* sender,
                      const ui::KeyEvent& key_event) override;

 private:
  struct Item {
    SpaceIcon icon;
    std::u16string label;
    int category = 0;
  };

  void Filter();
  bool HandleNavigationKey(const ui::KeyEvent& event);
  gfx::Rect SegmentRect(Page page) const;
  gfx::Rect GridRect() const;
  gfx::Rect CategoryRect(int index) const;
  gfx::Rect RemoveRect() const;
  gfx::Rect CellRect(size_t index) const;  // view coordinates (scrolled)
  std::optional<size_t> CellAt(const gfx::Point& p) const;
  int ContentHeight() const;
  void ScrollTo(int offset);
  void ScrollToCell(size_t index);
  void UpdateCategory();
  void PickIndex(size_t index);

  base::RepeatingCallback<void(const std::optional<SpaceIcon>&)> on_pick_;
  std::optional<SpaceIcon> current_;
  Page page_ = Page::kEmoji;
  raw_ptr<views::Textfield> search_ = nullptr;
  std::vector<Item> visible_;
  std::optional<size_t> hovered_;
  std::optional<size_t> pressed_;
  std::optional<size_t> focused_;
  int hovered_category_ = -1;
  int highlighted_category_ = 0;
  bool remove_hovered_ = false;
  int scroll_ = 0;
  space_editor::EditorColors colors_ = space_editor::EditorColors::For(true);
};

// ===========================================================================
// Space theme editor popover contents.
// ===========================================================================
struct OpenSpaceThemeEditorParams {
  OpenSpaceThemeEditorParams();
  OpenSpaceThemeEditorParams(const OpenSpaceThemeEditorParams&);
  OpenSpaceThemeEditorParams& operator=(const OpenSpaceThemeEditorParams&);
  ~OpenSpaceThemeEditorParams();

  SpaceID space_id;
  SpaceTheme theme;  // initial theme (Undo / Reset target)
  std::optional<std::string> title;
  std::optional<SpaceIcon> icon;
  ProfileID profile_id;
  std::vector<SpaceProfileChoice> profiles;
  // System appearance used by Automatic.
  theme::ContentAppearance system_appearance = theme::ContentAppearance::kDark;
  // Show the Theme / Space tabs (name, icon, Profile). False: theme only.
  bool show_identity = true;
  // Open on the Space page ("Change Icon…", "Rename…").
  bool open_identity_page = false;
  // Solid body override (else Open's light/dark popover body).
  std::optional<SkColor> panel_color;
};

class OpenSpaceThemeEditorView : public views::View,
                                 public views::TextfieldController,
                                 public ui::SimpleMenuModel::Delegate {
  METADATA_HEADER(OpenSpaceThemeEditorView, views::View)

 public:
  struct Callbacks {
    Callbacks();
    Callbacks(Callbacks&&);
    Callbacks& operator=(Callbacks&&);
    ~Callbacks();

    // Every drag frame / keyboard step: preview only (no save, no undo).
    base::RepeatingCallback<void(const SpaceID&, const SpaceTheme&)>
        on_live_theme_change;
    // Gesture end, preset, +/-, appearance, texture, Undo, Redo, Reset.
    base::RepeatingCallback<void(const SpaceID&, const SpaceTheme&)>
        on_commit_theme;
    base::RepeatingCallback<void(const SpaceID&, const std::string&)>
        on_rename_space;
    base::RepeatingCallback<void(const SpaceID&,
                                 const std::optional<SpaceIcon>&)>
        on_change_icon;
    base::RepeatingCallback<void(const SpaceID&, const ProfileID&)>
        on_change_profile;
    base::OnceClosure on_close;
  };

  enum class Page { kTheme, kSpace };

  OpenSpaceThemeEditorView(OpenSpaceThemeEditorParams params,
                           Callbacks callbacks);
  OpenSpaceThemeEditorView(const OpenSpaceThemeEditorView&) = delete;
  OpenSpaceThemeEditorView& operator=(const OpenSpaceThemeEditorView&) =
      delete;
  ~OpenSpaceThemeEditorView() override;

  const SpaceID& space_id() const { return params_.space_id; }
  const space_editor::ThemeEditorState& state() const { return state_; }
  const SpaceTheme& committed_theme() const { return committed_; }
  SkColor panel_color() const { return colors_.panel; }
  views::View* initial_focus() const;

  // Model changed elsewhere (sync, undo from the menu bar): adopt `theme`
  // unless it is the value this editor wrote last.
  void SynchronizeTheme(const SpaceTheme& theme);
  void SetSystemAppearance(theme::ContentAppearance appearance);

  void SelectPage(Page page);
  bool CanUndo() const { return !undo_.empty(); }
  bool CanRedo() const { return !redo_.empty(); }
  void Undo();
  void Redo();
  // Restores the theme the editor opened with (one undoable step).
  void ResetToInitial();
  // Ends gestures, commits pending preview and name edits.
  void FinishEditing();
  // Called once by the popover when its widget closes.
  void NotifyClosed();

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;
  bool AcceleratorPressed(const ui::Accelerator& accelerator) override;
  void OnThemeChanged() override;

  // views::TextfieldController:
  void ContentsChanged(views::Textfield* sender,
                       const std::u16string& new_contents) override;
  bool HandleKeyEvent(views::Textfield* sender,
                      const ui::KeyEvent& key_event) override;

  // ui::SimpleMenuModel::Delegate:
  void ExecuteCommand(int command_id, int event_flags) override;
  bool IsCommandIdChecked(int command_id) const override;

 private:
  // Ends a running pad / slider / dial gesture and commits it (before a
  // discrete action, Undo, page switch or close).
  void EndActiveGesture();
  // Action plumbing (ThemeEditorController.apply).
  enum class Kind { kGesture, kGestureEnd, kDiscrete, kNone };
  void Run(Kind kind, bool changed);
  void Render();
  void WritePreview();
  void Commit();
  void RestoreCommitted(const SpaceTheme& theme);
  void CommitName();
  void ShowProfileMenu();
  bool IsDark() const;

  OpenSpaceThemeEditorParams params_;
  Callbacks callbacks_;
  space_editor::ThemeEditorState state_;
  space_editor::EditorColors colors_;
  SpaceTheme initial_;
  SpaceTheme committed_;
  SpaceTheme last_written_;
  std::vector<SpaceTheme> undo_;
  std::vector<SpaceTheme> redo_;
  Page page_ = Page::kTheme;
  bool closed_ = false;
  std::u16string committed_name_;

  // Theme page.
  raw_ptr<views::View> theme_page_ = nullptr;
  raw_ptr<space_editor::ColorPadView> pad_ = nullptr;
  raw_ptr<space_editor::AppearanceModeBar> modes_ = nullptr;
  raw_ptr<space_editor::EditorButton> remove_ = nullptr;
  raw_ptr<space_editor::EditorButton> add_ = nullptr;
  raw_ptr<space_editor::PresetStripView> presets_ = nullptr;
  raw_ptr<space_editor::SineSliderView> intensity_ = nullptr;
  raw_ptr<space_editor::NoiseDialView> noise_ = nullptr;
  // Space page.
  raw_ptr<views::View> space_page_ = nullptr;
  raw_ptr<views::Textfield> name_field_ = nullptr;
  raw_ptr<OpenSpaceIconPickerView> icon_picker_ = nullptr;
  raw_ptr<space_editor::EditorButton> profile_button_ = nullptr;
  // Footer.
  raw_ptr<space_editor::EditorButton> theme_tab_ = nullptr;
  raw_ptr<space_editor::EditorButton> space_tab_ = nullptr;
  raw_ptr<space_editor::EditorButton> undo_button_ = nullptr;
  raw_ptr<space_editor::EditorButton> reset_button_ = nullptr;
  raw_ptr<space_editor::EditorButton> done_button_ = nullptr;

  std::unique_ptr<ui::SimpleMenuModel> profile_menu_model_;
  std::unique_ptr<views::MenuRunner> profile_menu_runner_;
};

// ===========================================================================
// New Space card.
// ===========================================================================
struct CreateSpaceRequest {
  CreateSpaceRequest();
  CreateSpaceRequest(const CreateSpaceRequest&);
  CreateSpaceRequest& operator=(const CreateSpaceRequest&);
  ~CreateSpaceRequest();

  std::string title;  // trimmed, never empty
  std::optional<SpaceIcon> icon;
  SpaceTheme theme;   // ThemeFromStyle(draft)
  ProfileID profile_id;  // empty when `new_profile_name` is set
  // "New Profile…": create this Profile and the Space together.
  std::optional<std::string> new_profile_name;
};

struct OpenSpaceCreationParams {
  OpenSpaceCreationParams();
  OpenSpaceCreationParams(const OpenSpaceCreationParams&);
  OpenSpaceCreationParams& operator=(const OpenSpaceCreationParams&);
  ~OpenSpaceCreationParams();

  std::vector<SpaceProfileChoice> profiles;
  ProfileID selected_profile_id;  // default: the first choice
  // Offer "New Profile…" (the profile card shows even with one Profile).
  bool allow_new_profile = true;
  std::u16string initial_title;
  std::optional<SpaceStyle> initial_style;
  std::optional<SpaceIcon> initial_icon;
  theme::ContentAppearance system_appearance = theme::ContentAppearance::kDark;
};

class OpenSpaceCreationView : public views::View,
                              public views::TextfieldController,
                              public ui::SimpleMenuModel::Delegate {
  METADATA_HEADER(OpenSpaceCreationView, views::View)

 public:
  struct Callbacks {
    Callbacks();
    Callbacks(Callbacks&&);
    Callbacks& operator=(Callbacks&&);
    ~Callbacks();

    base::OnceCallback<void(const CreateSpaceRequest&)> on_create;
    base::OnceClosure on_cancel;
    // Optional: the draft theme changed (live window preview of the draft).
    base::RepeatingCallback<void(const SpaceTheme&)> on_draft_theme;
  };

  OpenSpaceCreationView(OpenSpaceCreationParams params, Callbacks callbacks);
  OpenSpaceCreationView(const OpenSpaceCreationView&) = delete;
  OpenSpaceCreationView& operator=(const OpenSpaceCreationView&) = delete;
  ~OpenSpaceCreationView() override;

  views::Textfield* name_field() const { return name_field_; }
  const std::optional<SpaceStyle>& draft_style() const { return draft_; }
  SkColor body_color() const;
  // Replaces the draft (e.g. from a full theme editor opened in draft mode).
  void SetDraftStyle(std::optional<SpaceStyle> style);
  bool CanSubmit() const;
  void Submit();
  void Cancel();
  // Called once by the popover when its widget closes.
  void NotifyClosed();

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;
  void OnThemeChanged() override;
  bool OnMousePressed(const ui::MouseEvent& event) override;

  // views::TextfieldController:
  void ContentsChanged(views::Textfield* sender,
                       const std::u16string& new_contents) override;
  bool HandleKeyEvent(views::Textfield* sender,
                      const ui::KeyEvent& key_event) override;

  // ui::SimpleMenuModel::Delegate:
  void ExecuteCommand(int command_id, int event_flags) override;
  bool IsCommandIdChecked(int command_id) const override;

 private:
  int ContentHeight() const;
  int CardsTop() const;
  int ThemeCardTop() const;
  int ProfileCardTop() const;
  int ProfileCardHeight() const;
  gfx::Rect PageDotRect(int page) const;
  bool ShowsProfileCard() const;
  void ApplyColors();
  void ToggleIconPicker();
  void ShowProfileMenu();
  void PaintHeader(gfx::Canvas* canvas, const gfx::Rect& rect);
  void PaintPill(gfx::Canvas* canvas, const gfx::Rect& rect);
  const SpaceProfileChoice* SelectedProfile() const;
  void RefreshSubmitState();

  OpenSpaceCreationParams params_;
  Callbacks callbacks_;
  std::optional<SpaceStyle> draft_;
  std::optional<SpaceIcon> icon_;
  ProfileID selected_profile_;
  bool creating_profile_ = false;
  bool finished_ = false;
  bool picker_open_ = false;
  std::optional<std::u16string> profile_issue_;

  // Resolved from the draft theme.
  theme::ThemeStyle style_;
  theme::ContentAppearance mode_ = theme::ContentAppearance::kDark;
  SkColor title_color_ = SK_ColorWHITE;
  SkColor secondary_color_ = SK_ColorWHITE;
  SkColor card_fill_ = SK_ColorTRANSPARENT;
  SkColor focus_fill_ = SK_ColorTRANSPARENT;
  space_editor::EditorColors colors_ = space_editor::EditorColors::For(true);
  std::unique_ptr<theme::ThemePainter> painter_;

  raw_ptr<views::Textfield> name_field_ = nullptr;
  raw_ptr<views::Textfield> profile_name_field_ = nullptr;
  raw_ptr<space_editor::EditorButton> icon_button_ = nullptr;
  raw_ptr<OpenSpaceIconPickerView> icon_picker_ = nullptr;
  raw_ptr<space_editor::PresetStripView> swatches_ = nullptr;
  raw_ptr<space_editor::EditorButton> profile_button_ = nullptr;
  raw_ptr<space_editor::EditorButton> create_button_ = nullptr;
  raw_ptr<space_editor::EditorButton> cancel_button_ = nullptr;

  std::unique_ptr<ui::SimpleMenuModel> profile_menu_model_;
  std::unique_ptr<views::MenuRunner> profile_menu_runner_;
};

// ===========================================================================
// Anchored popovers.
// ===========================================================================
struct SpaceEditorAnchor {
  SpaceEditorAnchor();
  SpaceEditorAnchor(const SpaceEditorAnchor&);
  SpaceEditorAnchor& operator=(const SpaceEditorAnchor&);
  ~SpaceEditorAnchor();

  // The Space header, the bottom switcher's Space button, the "+" popover's
  // New Space row ... Takes priority over `screen_rect`.
  raw_ptr<views::View> view = nullptr;
  // Screen rect anchor (e.g. the sidebar's trailing edge, 35 pt below the
  // window top) with `parent` as the parent window.
  gfx::Rect screen_rect;
  gfx::NativeView parent = gfx::NativeView();
  // LEFT_TOP: the popover opens to the right of the anchor, top aligned
  // (Swift: sidebar trailing edge). Use TOP_LEFT / BOTTOM_LEFT under / above
  // a bottom-bar button.
  views::BubbleBorder::Arrow arrow = views::BubbleBorder::LEFT_TOP;
};

// Owns one popover (theme editor or creation card) at a time. Reopening
// replaces it (the old contents still report on_close / on_cancel).
// Callbacks must not destroy this object synchronously; post the release.
class OpenSpaceEditorPopover {
 public:
  OpenSpaceEditorPopover();
  OpenSpaceEditorPopover(const OpenSpaceEditorPopover&) = delete;
  OpenSpaceEditorPopover& operator=(const OpenSpaceEditorPopover&) = delete;
  ~OpenSpaceEditorPopover();

  OpenSpaceThemeEditorView* ShowThemeEditor(
      const SpaceEditorAnchor& anchor,
      OpenSpaceThemeEditorParams params,
      OpenSpaceThemeEditorView::Callbacks callbacks);
  OpenSpaceCreationView* ShowCreation(
      const SpaceEditorAnchor& anchor,
      OpenSpaceCreationParams params,
      OpenSpaceCreationView::Callbacks callbacks);

  void Close();
  bool IsShowing() const;
  views::Widget* widget() { return widget_.get(); }
  OpenSpaceThemeEditorView* theme_editor() { return theme_editor_; }
  OpenSpaceCreationView* creation() { return creation_; }

 private:
  friend views::Widget* ShowSpaceThemeEditorPopover(
      const SpaceEditorAnchor&,
      OpenSpaceThemeEditorParams,
      OpenSpaceThemeEditorView::Callbacks);
  friend views::Widget* ShowSpaceCreationPopover(
      const SpaceEditorAnchor&,
      OpenSpaceCreationParams,
      OpenSpaceCreationView::Callbacks);

  std::unique_ptr<views::BubbleDialogDelegate> MakeDelegate(
      const SpaceEditorAnchor& anchor,
      int corner_radius);
  void Open();
  // Discards the current bubble, then lets its contents finish.
  void ReplaceCurrent();
  void OnWidgetClosed(views::Widget::ClosedReason reason);
  void DiscardBubble(bool synchronous);

  std::unique_ptr<views::BubbleDialogDelegate> bubble_delegate_;
  std::unique_ptr<views::Widget> widget_;
  raw_ptr<OpenSpaceThemeEditorView> theme_editor_ = nullptr;
  raw_ptr<OpenSpaceCreationView> creation_ = nullptr;
  // Self-owned popovers (the free functions below) delete themselves after
  // their widget closes.
  bool self_owned_ = false;
  base::WeakPtrFactory<OpenSpaceEditorPopover> weak_factory_{this};
};

// Fire-and-forget helpers: open a self-owned popover and return its widget
// (valid until it closes; observe it or use the callbacks). Null on failure
// (no anchor view and no parent window).
views::Widget* ShowSpaceThemeEditorPopover(
    const SpaceEditorAnchor& anchor,
    OpenSpaceThemeEditorParams params,
    OpenSpaceThemeEditorView::Callbacks callbacks);
views::Widget* ShowSpaceCreationPopover(const SpaceEditorAnchor& anchor,
                                        OpenSpaceCreationParams params,
                                        OpenSpaceCreationView::Callbacks callbacks);

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_SPACE_EDITOR_VIEW_H_
