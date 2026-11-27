// Copyright 2026 The Open Authors. All rights reserved.
//
// Open design metrics in logical points (DIP). Ported value for value from
// Packages/OpenKit/Sources/OpenDesign/Metrics.swift, FeatureMetrics.swift,
// CommandBarTokens.swift and SiteControlTokens.swift. Frames are
// `[x, y, w, h]` from the window's (or the named container's) top-left corner,
// y grows down, measured on Arc 1.170.0 at sidebar width 228 unless a comment
// says otherwise. "guess" marks values the Swift source marks as unmeasured.
//
// This header is dependency-free (std only) so core, views, automation and
// WebUI code can all share one source of truth.

#ifndef OPEN_UNIFIED_UI_DESIGN_OPEN_METRICS_H_
#define OPEN_UNIFIED_UI_DESIGN_OPEN_METRICS_H_

#include <algorithm>
#include <cstdint>

#include "build/build_config.h"

namespace open_unified::metrics {

// A constexpr frame in points. Views code converts it with
// `gfx::RectF(r.x, r.y, r.w, r.h)` / `gfx::ToEnclosingRect`.
struct Frame {
  float x = 0;
  float y = 0;
  float w = 0;
  float h = 0;

  constexpr float right() const { return x + w; }
  constexpr float bottom() const { return y + h; }
  constexpr float center_x() const { return x + w / 2; }
  constexpr float center_y() const { return y + h / 2; }
};

struct SizeF {
  float w = 0;
  float h = 0;
};

// 0xRRGGBB plus an alpha in 0..1, sRGB unless a comment says Display P3.
struct HexColor {
  uint32_t rgb = 0;
  float alpha = 1.0f;
};

// ---------------------------------------------------------------------------
// Window chrome above the Space list (ChromeMetrics).
namespace chrome {
// Traffic lights: 16 pt frames at x 12 / 35 / 58, y 16; 12 pt circles centered.
inline constexpr Frame kTrafficLightFrames[3] = {
    {12, 16, 16, 16}, {35, 16, 16, 16}, {58, 16, 16, 16}};
inline constexpr float kTrafficLightDiameter = 12;
#if BUILDFLAG(IS_MAC)
inline constexpr float kTrafficLightsClearance = 76;
inline constexpr float kToolbarButtonSize = 32;
inline constexpr float kToolbarButtonY = 7;
inline constexpr float kSidebarToggleX = 77;
inline constexpr float kNavButtonPitch = 34;
#else
// Windows & Linux harmonized 32 DIP top caption strip: 28 x 28 buttons at y 2
// (vertical center y 16, matching OpenWindowControlsView and
// HiddenSidebarToggleButton with zero jump on toggle).
inline constexpr float kTrafficLightsClearance = 0;
inline constexpr float kToolbarButtonSize = 28;
inline constexpr float kToolbarButtonY = 2;
inline constexpr float kSidebarToggleX = 8;
inline constexpr float kNavButtonPitch = 30;
#endif
inline constexpr float kReloadTrailingInset = 6;
inline constexpr float kButtonPlateRadius = 6;
inline constexpr SizeF kSidebarToggleGlyph{19, 15};
inline constexpr SizeF kArrowGlyph{15, 12};
inline constexpr SizeF kReloadGlyph{14, 17};
// Developer Mode reload chevron.
inline constexpr float kDeveloperReloadShift = 6.25f;
inline constexpr float kReloadMenuCenterInset = 11.75f;
inline constexpr float kReloadMenuWidth = 16;
inline constexpr SizeF kReloadMenuGlyph{8.5f, 4.5f};

constexpr float ReloadX(float sidebar_width) {
  return sidebar_width - kReloadTrailingInset - kToolbarButtonSize;
}
constexpr float ForwardX(float sidebar_width) {
  return ReloadX(sidebar_width) - kNavButtonPitch;
}
constexpr float BackX(float sidebar_width) {
  return ReloadX(sidebar_width) - 2 * kNavButtonPitch;
}
}  // namespace chrome

// Compact sidebar toolbar (Back, Forward, More; 28 x 28 at y 9 on macOS,
// y 2 on Windows/Linux inside the 32 DIP strip, pitch 28).
namespace compact_toolbar {
// guess inside the measured 207..228 band.
inline constexpr float kSwitchWidth = 219;
inline constexpr float kButtonSize = 28;
#if BUILDFLAG(IS_MAC)
inline constexpr float kY = 9;
#else
inline constexpr float kY = 2;
#endif
inline constexpr float kPitch = 28;
inline constexpr float kTrailingInset = 6;
constexpr float MoreX(float w) { return w - kTrailingInset - kButtonSize; }
constexpr float ForwardX(float w) { return MoreX(w) - kPitch; }
constexpr float BackX(float w) { return MoreX(w) - 2 * kPitch; }
}  // namespace compact_toolbar

namespace chrome {
constexpr bool IsCompact(float sidebar_width) {
  return sidebar_width < compact_toolbar::kSwitchWidth;
}
}  // namespace chrome

// ---------------------------------------------------------------------------
// Windows 11 Fluent & Linux CSD caption controls.
namespace win_controls {
inline constexpr int kStripHeight = 32;
inline constexpr int kWinButtonW = 46;
inline constexpr int kWinButtonH = 32;
inline constexpr int kWinClusterW = 138;
inline constexpr int kLinuxButtonSize = 28;
inline constexpr int kLinuxButtonPlate = 24;
inline constexpr int kLinuxButtonGap = 4;
inline constexpr int kLinuxOuterMargin = 8;
inline constexpr int kLinuxCornerRadius = 12;
}  // namespace win_controls

// ---------------------------------------------------------------------------
// Command / URL field (the "URL pill").
namespace url_field {
#if BUILDFLAG(IS_MAC)
inline constexpr float kY = 46;
#else
// Windows & Linux: flush with panel.y = 32 (win_controls::kStripHeight).
inline constexpr float kY = 32;
#endif
inline constexpr float kHeight = 36;
inline constexpr float kInsetX = 8;  // == space_list::kRowFillInsetX
inline constexpr float kControlsTextGap = 8;
// A long host keeps its end visible; its leading 34 pt fade to clear.
inline constexpr float kLongHostFade = 34;
inline constexpr float kCornerRadius = 10;
inline constexpr Frame kMagnifierFrame{14, kY + 6, 24, 24};
inline constexpr float kPlaceholderX = 41;
inline constexpr float kHostX = 20;
inline constexpr float kTextY = kY + 9;
inline constexpr float kTextTrailingInset = 12;
inline constexpr float kTextBaselineOffset = 14;
// Copy URL [W - 70, kY + 3, 30, 30], Site Control Center [W - 42, kY + 3, 30, 30].
inline constexpr float kAccessorySize = 30;
inline constexpr float kAccessoryY = kY + 3;
inline constexpr float kSiteControlsTrailing = 12;
inline constexpr float kAccessoryPitch = 28;
constexpr Frame Pill(float sidebar_width) {
  return {kInsetX, kY, sidebar_width - 2 * kInsetX, kHeight};
}
constexpr Frame SiteControls(float w) {
  return {w - kSiteControlsTrailing - kAccessorySize, kAccessoryY,
          kAccessorySize, kAccessorySize};
}
constexpr Frame CopyUrl(float w) {
  return {w - kSiteControlsTrailing - kAccessorySize - kAccessoryPitch,
          kAccessoryY, kAccessorySize, kAccessorySize};
}
}  // namespace url_field

// ---------------------------------------------------------------------------
// Favorites grid ("Top Apps").
namespace favorites {
// Immediately below URL pill: 82 on macOS (46 + 36), 68 on Windows/Linux
// (32 + 36), so tiles / Spaces start at 76 DIP on Win/Linux after kInset (8).
inline constexpr float kSectionTop = url_field::kY + url_field::kHeight;
inline constexpr float kInset = 8;
inline constexpr float kTileHeight = 47;
inline constexpr float kColumnGap = 8;
inline constexpr float kRowGap = 8;
inline constexpr float kCornerRadius = url_field::kCornerRadius;
inline constexpr float kIconFrameSize = 18;
inline constexpr float kIconInkSize = 16;
// guess: below this tile width the grid drops to 3 columns.
inline constexpr float kMinTileWidthForFour = 44;
inline constexpr float kEmptyStateSectionHeight = 113;

constexpr float TileWidth(float sidebar_width, int columns) {
  return (sidebar_width - 2 * kInset - (columns - 1) * kColumnGap) /
         static_cast<float>(columns);
}
// Measured: 6 favorites -> 3 columns at width 228 and 500.
// guess: rows are balanced with at most 4 per row.
constexpr int Columns(int count, float sidebar_width) {
  if (count <= 0) {
    return 1;
  }
  const int max_columns =
      TileWidth(sidebar_width, 4) >= kMinTileWidthForFour ? 4 : 3;
  const int rows = (count + max_columns - 1) / max_columns;
  return (count + rows - 1) / rows;
}
constexpr float SectionHeight(int count, float sidebar_width) {
  if (count <= 0) {
    return kInset;
  }
  const int cols = Columns(count, sidebar_width);
  const int rows = (count + cols - 1) / cols;
  return 2 * kInset + rows * kTileHeight + (rows - 1) * kRowGap;
}
constexpr Frame EmptyCardFrame(float sidebar_width) {
  return {7, 7, std::max(0.0f, sidebar_width - 14), 95};
}
}  // namespace favorites

// ---------------------------------------------------------------------------
// Space header and tab list. Row offsets are relative to the row top.
namespace space_list {
inline constexpr float kUnreadDotSize = 6;
inline constexpr float kUnreadDotTrailingCenter = 26;
inline constexpr float kUnreadDotCenterY = 20;
// Header band 36 pt: icon [13, 5, 26, 26], title [41, 9, W - 58, 18].
inline constexpr float kHeaderHeight = 36;
inline constexpr Frame kHeaderIconFrame{13, 5, 26, 26};
inline constexpr float kHeaderTitleX = 41;
inline constexpr float kHeaderTitleY = 9;
inline constexpr float kHeaderTitleBaselineOffset = 14;
inline constexpr float kHeaderFillInsetX = 8;
inline constexpr float kHeaderMoreSize = 26;
inline constexpr float kHeaderMoreTrailing = 13;
inline constexpr float kSpacerRowHeight = 3;
inline constexpr float kRowHeight = 41;
inline constexpr float kRowFillInsetX = 8;
inline constexpr float kRowFillInsetTop = 2;
inline constexpr float kRowFillHeight = 36;
// Continuous corner, radius 12 (two capture sessions agree).
inline constexpr float kRowFillCornerRadius = 12;
inline constexpr float kFaviconX = 17;
inline constexpr float kFaviconY = 11;
inline constexpr float kFaviconSize = 18;
inline constexpr float kFaviconInk = 16;
inline constexpr float kTitleX = 43;
inline constexpr float kTitleTrailingInset = 17;
inline constexpr float kTitleBaselineOffset = 25;
inline constexpr float kTextInset = 1;
inline constexpr float kTextTrailingInset = 1;
inline constexpr float kHeaderTextInset = 3;
// Close (x) or unload (-) button [W - 39, y + 7, 26, 26].
inline constexpr float kAccessorySize = 26;
inline constexpr float kAccessoryY = 7;
inline constexpr float kAccessoryTrailingInset = 13;
inline constexpr float kIndentPerLevel = 16;
inline constexpr float kFolderPeekDotDiameter = 3;
inline constexpr float kFolderPeekDotPitch = 4;
inline constexpr float kFolderPeekDotFirstX = 5;
inline constexpr float kFolderPeekDotY = 10;
inline constexpr SizeF kFolderUnloadInk{12, 2};
inline constexpr float kSplitDividerWidth = 1;
// Selected split row: one cell per pane inside the card.
inline constexpr float kSplitCellInset = 4;
inline constexpr float kSplitCellGap = 4;
inline constexpr float kSplitCellTop = 6;
inline constexpr float kSplitCellHeight = 28;
inline constexpr float kSplitCellCornerRadius = 8;
// Peek badge on the source row.
inline constexpr float kPeekBadgeTrailingInset = 38;
inline constexpr float kPeekBadgeY = 8;
inline constexpr float kPeekBadgeSize = 24;
inline constexpr float kPeekBadgeCornerRadius = 6;
// "/" before a pinned tab's title once it left its pinned URL.
inline constexpr SizeF kPinnedSlashSize{2, 14.5f};
inline constexpr float kPinnedSlashAngle = 0.14f;  // radians from vertical
inline constexpr float kPinnedSlashCenterX = -3;
inline constexpr float kPinnedSlashCenterY = 19.5f;
inline constexpr float kPinnedSlashTitleShift = 2;
// Pinned/Today divider row: 17 pt, 1 pt line at y + 7 from x 18 to W - 18.
inline constexpr float kDividerRowHeight = 17;
inline constexpr float kDividerLineY = 7;
inline constexpr float kDividerLineInset = 18;
// "Clear": arrow [W - 58, y + 3, 12, 9], label [W - 46, y, 29, 15];
// the line then ends at W - 66. Negative x values are from the right edge.
inline constexpr Frame kClearArrowFrame{-58, 3, 12, 9};
inline constexpr float kClearLabelX = -46;
inline constexpr float kClearLabelWidth = 29;
inline constexpr float kClearLabelHeight = 15;
inline constexpr float kClearLabelBaseline = 11;
inline constexpr float kClearLineEnd = -66;
inline constexpr float kNewTabGlyphInk = 11;
inline constexpr float kNewTabGlyphX = 20;

constexpr Frame RowFill(float width, float indent = 0) {
  return {kRowFillInsetX + indent, kRowFillInsetTop,
          width - 2 * kRowFillInsetX - indent, kRowFillHeight};
}
constexpr Frame Accessory(float width) {
  return {width - kAccessoryTrailingInset - kAccessorySize, kAccessoryY,
          kAccessorySize, kAccessorySize};
}
constexpr Frame ResetGlyphPlate(float indent) {
  return {16 + indent, 10, 20, 20};
}
}  // namespace space_list

// ---------------------------------------------------------------------------
// Row media (speaker) button: AX [41, y + 7, 26, 26]; title moves 43 -> 69.
namespace row_media {
inline constexpr float kButtonSize = 26;
inline constexpr float kButtonX = 41;
inline constexpr float kButtonY = 7;
inline constexpr float kTitleShift = 26;
}  // namespace row_media

// ---------------------------------------------------------------------------
// Bottom bar: Library (Home), Space switcher, plus.
namespace bottom_bar {
inline constexpr float kHeight = 50;
inline constexpr float kButtonSize = 32;
inline constexpr float kButtonY = 9;
inline constexpr float kHomeX = 8;
inline constexpr float kPlusTrailingInset = 8;
// Switcher strip [42, 0, W - 84, 50]; items 36 x 34 at pitch 34, y 8.
inline constexpr float kSwitcherLeading = 42;
inline constexpr float kSwitcherTrailing = 42;
inline constexpr SizeF kSwitcherItemSize{36, 34};
inline constexpr float kSwitcherPitch = 34;
inline constexpr float kSwitcherItemY = 8;
inline constexpr SizeF kSwitcherPlateInset{1, 1};
inline constexpr float kSwitcherEmojiSize = 14;
// GUESS: overflow fade width and reveal duration.
inline constexpr float kSwitcherFadeWidth = 28;
inline constexpr double kSwitcherRevealDuration = 0.2;
inline constexpr float kPlateRadius = 6;
// Other Spaces' icons in the switcher.
inline constexpr float kInactiveIconOpacity = 0.55f;

constexpr Frame Home() { return {kHomeX, kButtonY, kButtonSize, kButtonSize}; }
constexpr Frame Plus(float w) {
  return {w - kPlusTrailingInset - kButtonSize, kButtonY, kButtonSize,
          kButtonSize};
}
constexpr Frame Switcher(float w) {
  return {kSwitcherLeading, 0, w - kSwitcherLeading - kSwitcherTrailing,
          kHeight};
}
}  // namespace bottom_bar

// ---------------------------------------------------------------------------
// Web content panel next to the sidebar.
namespace panel {
inline constexpr float kInset = 10;
inline constexpr float kCornerRadius = 6;
// CSS `0 1px 6px rgba(0,0,0,.25)`.
inline constexpr float kShadowOpacity = 0.25f;
inline constexpr float kShadowBlur = 6;  // CSS blur; Gaussian sigma = 3
inline constexpr float kShadowOffsetY = 1;
inline constexpr double kEmptyFillWhiteAlpha = 0.10;

// [sidebarWidth, top_inset, W - sidebarWidth - 10, H - top_inset - 10];
// hidden: [10, top_inset, W - 20, H - top_inset - 10].
constexpr Frame PanelFrame(SizeF window,
                           float sidebar_width,
                           bool sidebar_hidden,
                           float top_inset = kInset) {
  const float x = sidebar_hidden ? kInset : sidebar_width;
  return {x, top_inset, window.w - x - kInset, window.h - top_inset - kInset};
}
}  // namespace panel

// ---------------------------------------------------------------------------
// Window-level values.
namespace window {
inline constexpr float kDefaultSidebarWidth = 228;
inline constexpr float kMaxSidebarWidth = 500;
inline constexpr float kMinSidebarWidth = 164;
// Guess inside the captured 65..85 pt band.
inline constexpr float kSidebarDragHidePoint = 82;
inline constexpr float kCornerRadius = 16;
// Hover-reveal card [5, 5, S, H - 10]; circular radius 12.
inline constexpr float kRevealCardInset = 5;
inline constexpr float kRevealCardRadius = 12;
inline constexpr float kRevealCardStrokeWidth = 1;
inline constexpr HexColor kRevealCardStroke{0xFFFFFF, 0.30f};
// Black, no offset, Gaussian sigma ~4, peak 0.17.
inline constexpr float kRevealCardShadowOpacity = 0.17f;
inline constexpr float kRevealCardShadowRadius = 4;
// Resize sash: 4 pt centered on the sidebar edge.
inline constexpr float kResizeHandleWidth = 4;

constexpr Frame RevealCardFrame(SizeF window, float sidebar_width) {
  return {kRevealCardInset, kRevealCardInset, sidebar_width,
          std::max(0.0f, window.h - 2 * kRevealCardInset)};
}
constexpr float ClampSidebarWidth(float w) {
  return std::clamp(w, kMinSidebarWidth, kMaxSidebarWidth);
}
}  // namespace window

// Hover reveal zones while the sidebar is hidden (WindowHoverTracker facts).
namespace reveal {
inline constexpr double kDwell = 0.15;
inline constexpr double kOuterEdgeDwell = 0.16;
inline constexpr double kExitDelay = 0.25;
inline constexpr float kHoldRightMargin = 16;
inline constexpr float kPassThroughVelocity = 1800.f;
inline constexpr float kZoneUnit = 10;      // guess: the 10 pt content inset
inline constexpr float kInnerEdgeWidth = 0.6f * kZoneUnit;
inline constexpr float kInnerEdgeHeldMin = -2 * kZoneUnit;
inline constexpr float kInnerEdgeHeldMax = 1.5f * kZoneUnit;
inline constexpr float kOuterEdgeHeld = 250;
inline constexpr float kOuterEdgeApproach = 50;
inline constexpr float kTopLeftWidth = 40;
inline constexpr float kTopLeftMin = -1.5f * kZoneUnit;
inline constexpr float kTopLeftMax = 2 * kZoneUnit;
inline constexpr float kTrafficLightRegionHeight = 50;
}  // namespace reveal

// ---------------------------------------------------------------------------
namespace tooltip {
inline constexpr float kHeight = 27;
inline constexpr float kTwoLineHeight = 42;
inline constexpr float kHorizontalPadding = 11;
inline constexpr float kKeycapHeight = 17;
inline constexpr float kKeycapMinWidth = 17;
inline constexpr float kKeycapRadius = 4;
inline constexpr float kKeycapGap = 3;
inline constexpr float kLabelToKeycaps = 7;
inline constexpr float kAnchorGap = 6;   // guess
inline constexpr double kShowDelay = 0.6;  // guess
}  // namespace tooltip

// ---------------------------------------------------------------------------
// Split View (SplitMetrics).
namespace split {
inline constexpr float kGap = 10;
inline constexpr float kBarHeight = 32;  // PaneChromeView
inline constexpr float kRingWidth = 2;
inline constexpr HexColor kRingColor{0x3139FF, 1.0f};
inline constexpr float kMinimumPane = 200;
inline constexpr Frame kBack{5, 4, 32, 24};
inline constexpr Frame kForward{42, 4, 32, 24};
inline constexpr Frame kReload{79, 4, 32, 24};
inline constexpr float kHostSlot = 25;
inline constexpr float kBarControlGap = 4;    // guess
inline constexpr float kHostMinimumWidth = 28;  // guess
}  // namespace split

// Peek (PeekMetrics).
namespace peek {
inline constexpr float kWidthFraction = 0.80f;
inline constexpr float kVerticalInset = 2;
inline constexpr float kButtonDiameter = 33;
inline constexpr float kButtonHitWidth = 35;
inline constexpr float kButtonGap = 13;
inline constexpr float kButtonTop = 9;
inline constexpr float kButtonPitch = 43;
inline constexpr float kScrimAlpha = 0.70f;
inline constexpr HexColor kDefaultControls{0x050627, 1.0f};
inline constexpr HexColor kDefaultScrim{0x000013, 0.70f};
inline constexpr HexColor kDefaultGlyph{0xF0F1FF, 1.0f};
inline constexpr float kShadowOpacity = 0.18f;
inline constexpr float kShadowRadius = 8;
}  // namespace peek

// Command Bar (CommandBarMetrics).
namespace command_bar {
// Outer width, border included (Swift ships 768). The RE pixel span
// x 725...1490 reads 766 (docs/re/interaction-states.md, F0049).
inline constexpr float kWidth = 768;
inline constexpr float kMeasuredSpanWidth = 766;
inline constexpr float kCornerRadius = 12;
inline constexpr float kInputRowHeight = 64;
inline constexpr float kSeparatorHeight = 1;
inline constexpr float kListTop = 69;
inline constexpr float kRowInsetX = 8;
inline constexpr float kRowHeight = 50;
inline constexpr int kMaxVisibleRows = 5;
inline constexpr float kBottomPadding = 10;
inline constexpr float kEmptyListHeight = 64;  // guess
inline constexpr float kMinimumWindowMargin = 40;  // guess
inline constexpr float kCenteringHeight = 339;
// Embedded (Little Open) panel: header 79 + 5 x 50 = 329.
inline constexpr float kEmbeddedHeader = 79;
inline constexpr float kLittleOpenWidth = 490;
inline constexpr int kLittleOpenRows = 5;
inline constexpr float kInlineMinimumWidth = 340;
}  // namespace command_bar

// Little Open (LittleOpenMetrics).
namespace little_open {
inline constexpr SizeF kBarSize{490, 329};
inline constexpr float kScreenInset = 20;
inline constexpr SizeF kPageSize{1185, 832};
inline constexpr SizeF kMinimumPageSize{360, 240};
inline constexpr float kTitleBarHeight = 47;
inline constexpr Frame kTrafficLights[3] = {
    {9, 16, 16, 16}, {32, 16, 16, 16}, {55, 16, 16, 16}};
inline constexpr HexColor kTitleBarFill{0x272A37, 1.0f};
inline constexpr HexColor kCapsuleFill{0x3D3D4A, 1.0f};
inline constexpr HexColor kPillFill{0x050627, 1.0f};
inline constexpr HexColor kText{0xFFFFFF, 0.8f};
inline constexpr float kFontSize = 13;
inline constexpr float kCapsuleHeight = 31;
inline constexpr float kCapsuleRadius = 8;
inline constexpr float kPillRadius = 15;
inline constexpr SizeF kPillSize{188, 30};
inline constexpr float kWindowCornerRadius = command_bar::kCornerRadius;
constexpr Frame Capsule(float w) {
  return {84, 8, std::max(0.0f, w - 289), kCapsuleHeight};
}
constexpr Frame Pill(float w) { return {w - 196, 8, 188, 30}; }
constexpr Frame Copy(float w) { return {w - 228, 16, 16, 16}; }
constexpr Frame Chevron(float w) { return {w - 29, 15, 16, 16}; }
}  // namespace little_open

// Site Control Center popover (SiteControlTokens).
namespace site_control {
inline constexpr float kWidth = 236;
inline constexpr float kPadding = 10;
inline constexpr float kCornerRadius = 16;
inline constexpr float kMaxHeight = 640;
inline constexpr float kInUseDot = 6;
}  // namespace site_control

// Content toolbar (single-pane PaneChromeView equivalent).
namespace content_toolbar {
inline constexpr float kHeight = split::kBarHeight;
inline constexpr float kSinglePaneHeight = 36;
}  // namespace content_toolbar

}  // namespace open_unified::metrics

#endif  // OPEN_UNIFIED_UI_DESIGN_OPEN_METRICS_H_
