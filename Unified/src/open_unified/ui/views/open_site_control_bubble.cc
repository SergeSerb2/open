// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_site_control_bubble.h"

#include <algorithm>
#include <array>
#include <utility>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/strings/string_number_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/mojom/dialog_button.mojom.h"
#include "ui/base/mojom/menu_source_type.mojom.h"
#include "ui/events/event.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/bubble/bubble_border.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/controls/menu/menu_runner.h"
#include "ui/views/controls/menu/menu_types.h"

namespace open_unified {

namespace {

using secondary::Glyph;
using secondary::GlyphButton;
using secondary::PaintedButton;
namespace m = site_control_metrics;

// SiteControlColors (Light D3 / Dark Arc 1.170 measured).
constexpr SkColor kActionFillTopLight = SkColorSetRGB(0xFA, 0xFA, 0xFA);
constexpr SkColor kActionFillTopDark = SkColorSetRGB(0x27, 0x27, 0x27);
constexpr SkColor kActionFillBottomLight = SkColorSetRGB(0xFA, 0xFA, 0xFA);
constexpr SkColor kActionFillBottomDark = SkColorSetRGB(0x16, 0x16, 0x16);
constexpr SkColor kActionHighlightDark = SkColorSetRGB(0x57, 0x57, 0x57);
constexpr SkColor kGlyphLight = SkColorSetRGB(0x3A, 0x38, 0x2F);
constexpr SkColor kLabelLight = SkColorSetRGB(0x26, 0x24, 0x1C);
constexpr SkColor kLabelDark = SkColorSetRGB(0xDB, 0xDB, 0xDF);
constexpr SkColor kRowTitleLight = SkColorSetRGB(0x26, 0x24, 0x1C);
constexpr SkColor kRowTitleDark = SkColorSetRGB(0xDF, 0xDF, 0xE2);
constexpr SkColor kRowSubtitleDark = SkColorSetRGB(0x9F, 0x9E, 0xA9);
constexpr SkColor kCircleOnLight = SkColorSetRGB(0x2B, 0x2A, 0x3C);
constexpr SkColor kCircleOnDark = SkColorSetRGB(0xEC, 0xED, 0xFF);
constexpr SkColor kSeparatorDark = SkColorSetRGB(0x23, 0x23, 0x23);
constexpr SkColor kInsecureTextLight = SkColorSetRGB(0xD8, 0x43, 0x2C);
constexpr SkColor kInsecureTextDark = SkColorSetRGB(0xF2, 0x5E, 0x6B);
// Solid panel body (Open choice, see header).
constexpr SkColor kPanelLight = SkColorSetRGB(0xF4, 0xF3, 0xEC);
constexpr SkColor kPanelDark = SkColorSetRGB(0x2C, 0x2C, 0x33);

constexpr int kTitleFontSize = 14;     // siteControlRowTitle 14 semibold
constexpr int kSubtitleFontSize = 13;  // siteControlRowSubtitle 13 regular
constexpr int kLabelFontSize = 14;     // siteControlLabel 14 semibold
constexpr int kPillFontSize = 14;      // siteControlPill 14 medium

// Permission menu commands.
enum : int {
  kMenuAsk = 1,
  kMenuAllow,
  kMenuBlock,
};
constexpr int kMenuGroup = 1;

std::u16string PermissionTitle(SitePermissionKind kind) {
  switch (kind) {
    case SitePermissionKind::kCamera:
      return u"Camera";
    case SitePermissionKind::kMicrophone:
      return u"Microphone";
    case SitePermissionKind::kLocation:
      return u"Location";
    case SitePermissionKind::kNotifications:
      return u"Notifications";
    case SitePermissionKind::kPopups:
      return u"Pop-ups";
  }
  return std::u16string();
}

Glyph PermissionGlyph(SitePermissionKind kind) {
  switch (kind) {
    case SitePermissionKind::kCamera:
      return Glyph::kCamera;
    case SitePermissionKind::kMicrophone:
      return Glyph::kMicrophone;
    case SitePermissionKind::kLocation:
      return Glyph::kLocation;
    case SitePermissionKind::kNotifications:
      return Glyph::kBell;
    case SitePermissionKind::kPopups:
      return Glyph::kPopup;
  }
  return Glyph::kNone;
}

std::u16string SettingLabel(SitePermissionSetting setting) {
  switch (setting) {
    case SitePermissionSetting::kAsk:
      return u"Ask";
    case SitePermissionSetting::kAllow:
      return u"Allowed";
    case SitePermissionSetting::kBlock:
      return u"Blocked";
  }
  return std::u16string();
}

}  // namespace

// --- OpenSiteControlView -----------------------------------------------------

OpenSiteControlView::OpenSiteControlView(
    SiteControlDelegate* delegate,
    const SiteControlState& state,
    const secondary::Appearance& appearance)
    : delegate_(delegate), state_(state), appearance_(appearance) {
  GetViewAccessibility().SetRole(ax::mojom::Role::kGroup);
  GetViewAccessibility().SetName(u"Site Controls");

  struct ActionSpec {
    const char16_t* name;
    SiteControlAction action;
  };
  static constexpr std::array<ActionSpec, 4> kActions = {{
      {u"Copy URL", SiteControlAction::kCopyUrl},
      {u"New Boost", SiteControlAction::kNewBoost},
      {u"Split View", SiteControlAction::kSplit},
      {u"Capture", SiteControlAction::kCapture},
  }};
  for (int i = 0; i < 4; ++i) {
    action_tiles_.push_back(AddChildView(std::make_unique<PaintedButton>(
        base::BindRepeating(
            [](OpenSiteControlView* self, SiteControlAction action) {
              if (self->delegate_) {
                self->delegate_->OnSiteControlAction(action);
              }
            },
            base::Unretained(this), kActions[i].action),
        base::BindRepeating(&OpenSiteControlView::PaintActionTile,
                            base::Unretained(this), i),
        kActions[i].name)));
  }

  ad_block_row_ = AddChildView(std::make_unique<PaintedButton>(
      base::BindRepeating(
          [](OpenSiteControlView* self) {
            const bool enabled = !self->state_.ad_block_enabled;
            self->SetAdBlockState(enabled, self->state_.ad_block_blocked_count);
            if (self->delegate_) {
              self->delegate_->OnSiteControlAdBlockToggled(enabled);
            }
          },
          base::Unretained(this)),
      base::BindRepeating(&OpenSiteControlView::PaintAdBlockRow,
                          base::Unretained(this)),
      u"Ad Blocking"));

  pill_ = AddChildView(std::make_unique<PaintedButton>(
      base::BindRepeating(
          [](OpenSiteControlView* self) {
            if (self->delegate_) {
              self->delegate_->OnSiteControlAction(
                  SiteControlAction::kSiteSettings);
            }
          },
          base::Unretained(this)),
      base::BindRepeating(&OpenSiteControlView::PaintPill,
                          base::Unretained(this)),
      u"Site Settings"));

  auto clear = std::make_unique<GlyphButton>(
      base::BindRepeating(
          [](OpenSiteControlView* self) {
            if (self->delegate_) {
              self->delegate_->OnSiteControlAction(
                  SiteControlAction::kClearSiteData);
            }
          },
          base::Unretained(this)),
      Glyph::kTrash, u"Clear Site Data");
  clear->SetGlyphSize(15.f);
  clear_button_ = AddChildView(std::move(clear));

  Rebuild();
}

OpenSiteControlView::~OpenSiteControlView() = default;

SkColor OpenSiteControlView::panel_color() const {
  return state_.panel_color.value_or(appearance_.dark ? kPanelDark
                                                      : kPanelLight);
}

void OpenSiteControlView::SetState(const SiteControlState& state) {
  state_ = state;
  Rebuild();
}

void OpenSiteControlView::SetAdBlockState(bool enabled, int blocked_count) {
  if (state_.ad_block_enabled == enabled &&
      state_.ad_block_blocked_count == blocked_count) {
    return;
  }
  state_.ad_block_enabled = enabled;
  state_.ad_block_blocked_count = blocked_count;
  ad_block_row_->SchedulePaint();
}

views::View* OpenSiteControlView::GetExtensionAnchor(
    const std::string& extension_id) {
  for (size_t i = 0;
       i < state_.extensions.size() && i < extension_tiles_.size(); ++i) {
    if (state_.extensions[i].id == extension_id) {
      return extension_tiles_[i];
    }
  }
  return nullptr;
}

void OpenSiteControlView::Rebuild() {
  // Extension tiles and permission rows follow the state; the fixed controls
  // stay.
  for (auto& tile : extension_tiles_) {
    RemoveChildViewT(tile.get());
  }
  extension_tiles_.clear();
  for (auto& row : permission_rows_) {
    RemoveChildViewT(row.get());
  }
  permission_rows_.clear();

  for (size_t i = 0; i < state_.extensions.size(); ++i) {
    auto tile = std::make_unique<PaintedButton>(
        base::BindRepeating(
            [](OpenSiteControlView* self, size_t index) {
              if (!self->delegate_ || index >= self->state_.extensions.size() ||
                  index >= self->extension_tiles_.size()) {
                return;
              }
              self->delegate_->OnSiteControlExtensionPressed(
                  self->state_.extensions[index].id,
                  self->extension_tiles_[index]);
            },
            base::Unretained(this), i),
        base::BindRepeating(&OpenSiteControlView::PaintExtensionTile,
                            base::Unretained(this), i),
        state_.extensions[i].name);
    tile->SetEnabled(state_.extensions[i].enabled);
    extension_tiles_.push_back(AddChildView(std::move(tile)));
  }
  for (size_t i = 0; i < state_.permissions.size(); ++i) {
    permission_rows_.push_back(AddChildView(std::make_unique<PaintedButton>(
        base::BindRepeating(&OpenSiteControlView::ShowPermissionMenu,
                            base::Unretained(this), i),
        base::BindRepeating(&OpenSiteControlView::PaintPermissionRow,
                            base::Unretained(this), i),
        PermissionTitle(state_.permissions[i].kind))));
  }
  // Keyboard order follows the panel: tiles, extensions, permission rows,
  // ad blocking, footer.
  size_t order = action_tiles_.size();
  for (auto& tile : extension_tiles_) {
    ReorderChildView(tile, order++);
  }
  for (auto& row : permission_rows_) {
    ReorderChildView(row, order++);
  }
  ad_block_row_->SetVisible(state_.ad_block_available);
  action_tiles_[2]->SetEnabled(state_.split_available);
  pill_->GetViewAccessibility().SetName(u"Site Settings for " + state_.host);
  scroll_ = 0;
  PreferredSizeChanged();
  InvalidateLayout();
  SchedulePaint();
}

int OpenSiteControlView::ContentHeight() const {
  int y = m::kPadding + m::kActionHeight;  // Tiles.
  const bool has_extensions = !state_.extensions.empty();
  const size_t rows =
      state_.permissions.size() + (state_.ad_block_available ? 1 : 0);
  if (has_extensions) {
    const int grid_rows =
        static_cast<int>((state_.extensions.size() + m::kExtensionColumns - 1) /
                         m::kExtensionColumns);
    y += m::kGapAfterActions + (grid_rows - 1) * m::kExtensionRowPitch +
         m::kActionHeight;
  }
  if (rows > 0) {
    y += (has_extensions ? m::kSectionGap : m::kGapAfterActions) +
         static_cast<int>(rows - 1) * m::kRowPitch + m::kRowIcon;
  }
  y += m::kGapBeforeSeparator + 1 + m::kGapAfterSeparator + m::kFooterHeight +
       m::kPadding;
  return y;
}

gfx::Size OpenSiteControlView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  // height = min(content, maxHeight); the bubble also clamps to window room.
  return gfx::Size(m::kWidth, std::min(ContentHeight(), m::kMaxHeight));
}

void OpenSiteControlView::Layout(PassKey) {
  const int inner = m::kWidth - 2 * m::kPadding;
  int y = m::kPadding - scroll_;
  for (int i = 0; i < 4; ++i) {
    action_tiles_[i]->SetBoundsRect(
        gfx::Rect(m::kPadding + i * (m::kActionWidth + m::kActionGap), y,
                  m::kActionWidth, m::kActionHeight));
  }
  y += m::kActionHeight;

  extensions_label_y_ = -1;
  if (!extension_tiles_.empty()) {
    y += m::kGapAfterActions;
    extensions_label_y_ = y - m::kLabelBaselineAboveContent;
    for (size_t i = 0; i < extension_tiles_.size(); ++i) {
      const int col = static_cast<int>(i % m::kExtensionColumns);
      const int row = static_cast<int>(i / m::kExtensionColumns);
      extension_tiles_[i]->SetBoundsRect(gfx::Rect(
          m::kPadding + col * (m::kActionWidth + m::kActionGap),
          y + row * m::kExtensionRowPitch, m::kActionWidth, m::kActionHeight));
    }
    const int grid_rows =
        static_cast<int>((extension_tiles_.size() + m::kExtensionColumns - 1) /
                         m::kExtensionColumns);
    y += (grid_rows - 1) * m::kExtensionRowPitch + m::kActionHeight;
  }

  permissions_label_y_ = -1;
  const bool has_rows =
      !permission_rows_.empty() || ad_block_row_->GetVisible();
  if (has_rows) {
    y += extension_tiles_.empty() ? m::kGapAfterActions : m::kSectionGap;
    permissions_label_y_ = y - m::kLabelBaselineAboveContent;
    int row_y = y;
    for (auto& row : permission_rows_) {
      row->SetBoundsRect(gfx::Rect(m::kPadding, row_y, inner, m::kRowIcon));
      row_y += m::kRowPitch;
    }
    if (ad_block_row_->GetVisible()) {
      ad_block_row_->SetBoundsRect(
          gfx::Rect(m::kPadding, row_y, inner, m::kRowIcon));
      row_y += m::kRowPitch;
    }
    y = row_y - m::kRowPitch + m::kRowIcon;
  }

  y += m::kGapBeforeSeparator;
  separator_y_ = y;
  y += 1 + m::kGapAfterSeparator;
  pill_->SetBoundsRect(gfx::Rect(m::kPadding, y,
                                 inner - m::kMoreButton - m::kActionGap,
                                 m::kFooterHeight));
  clear_button_->SetBoundsRect(
      gfx::Rect(m::kWidth - m::kPadding - m::kMoreButton, y, m::kMoreButton,
                m::kMoreButton));
  clear_button_->SetPlate(
      GlyphButton::Plate::kCircle,
      Color(secondary::WithAlpha(SkColorSetRGB(128, 128, 128), 0.18f),
            secondary::WithAlpha(SK_ColorBLACK, 0.28f)),
      m::kMoreButton / 2.f);
  clear_button_->SetGlyphColor(
      Color(kGlyphLight, secondary::WithAlpha(SK_ColorWHITE, 0.85f)));
  clear_button_->SetHoverFill(secondary::WithAlpha(
      appearance_.dark ? SK_ColorWHITE : SK_ColorBLACK, 0.06f));
}

void OpenSiteControlView::OnPaint(gfx::Canvas* canvas) {
  canvas->DrawColor(panel_color());
  const gfx::FontList label =
      secondary::FontOfSize(kLabelFontSize, gfx::Font::Weight::SEMIBOLD);
  const SkColor label_color = Color(kLabelLight, kLabelDark);
  const int line = label.GetHeight();
  // Labels sit with their baseline 14 pt above the section content.
  auto draw_label = [&](const std::u16string& text, int baseline_y) {
    const int top = baseline_y - label.GetBaseline();
    secondary::DrawText(
        canvas, text, label, label_color,
        gfx::Rect(m::kPadding, top, m::kWidth - 2 * m::kPadding, line));
  };
  if (extensions_label_y_ >= 0) {
    draw_label(u"Extensions", extensions_label_y_);
  }
  if (permissions_label_y_ >= 0) {
    draw_label(u"Permissions", permissions_label_y_);
  }
  canvas->FillRect(
      gfx::Rect(0, separator_y_, m::kWidth, 1),
      Color(secondary::WithAlpha(SK_ColorBLACK, 0.10f), kSeparatorDark));
}

bool OpenSiteControlView::OnMouseWheel(const ui::MouseWheelEvent& event) {
  const int overflow = std::max(0, ContentHeight() - height());
  if (overflow == 0) {
    return false;
  }
  scroll_ = std::clamp(scroll_ - event.y_offset(), 0, overflow);
  InvalidateLayout();
  SchedulePaint();
  return true;
}

void OpenSiteControlView::PaintActionTile(int index,
                                          gfx::Canvas* canvas,
                                          const gfx::Rect& bounds,
                                          bool hovered) {
  static constexpr std::array<Glyph, 4> kGlyphs = {
      Glyph::kLink, Glyph::kBoost, Glyph::kSplit, Glyph::kCapture};
  const gfx::RectF tile(bounds);
  // Gradient tile, 1 pt ring, dark 1 pt top highlight (SiteControlColors).
  secondary::FillRoundRectGradient(
      canvas, tile, m::kActionRadius,
      Color(kActionFillTopLight, kActionFillTopDark),
      Color(kActionFillBottomLight, kActionFillBottomDark));
  if (hovered) {
    secondary::FillRoundRect(
        canvas, tile, m::kActionRadius,
        secondary::WithAlpha(appearance_.dark ? SK_ColorWHITE : SK_ColorBLACK,
                             0.05f));
  }
  if (appearance_.dark) {
    canvas->FillRect(gfx::Rect(bounds.x() + m::kActionRadius, bounds.y(),
                               bounds.width() - 2 * m::kActionRadius, 1),
                     kActionHighlightDark);
  }
  secondary::StrokeRoundRect(canvas, tile, m::kActionRadius,
                             Color(secondary::WithAlpha(SK_ColorBLACK, 0.08f),
                                   secondary::WithAlpha(SK_ColorBLACK, 0.30f)),
                             1.f);
  SkColor glyph =
      Color(kGlyphLight, secondary::WithAlpha(SK_ColorWHITE, 0.85f));
  if (index == 1 && state_.boost_active) {
    glyph = appearance_.ActiveAccent();
  }
  if (!action_tiles_[index]->GetEnabled()) {
    glyph = secondary::WithAlpha(glyph, 0.3f);
  }
  const float g = m::kActionGlyph;
  secondary::PaintGlyph(canvas, kGlyphs[index],
                        gfx::RectF(tile.CenterPoint().x() - g / 2.f,
                                   tile.CenterPoint().y() - g / 2.f, g, g),
                        glyph);
}

void OpenSiteControlView::PaintExtensionTile(size_t index,
                                             gfx::Canvas* canvas,
                                             const gfx::Rect& bounds,
                                             bool hovered) {
  if (index >= state_.extensions.size()) {
    return;
  }
  const SiteControlExtensionItem& item = state_.extensions[index];
  const gfx::RectF tile(bounds);
  secondary::FillRoundRect(
      canvas, tile, m::kTileRadius,
      Color(secondary::WithAlpha(SK_ColorBLACK, hovered ? 0.11f : 0.07f),
            secondary::WithAlpha(SK_ColorWHITE, hovered ? 0.12f : 0.08f)));
  const gfx::Rect icon(bounds.CenterPoint().x() - m::kExtensionIcon / 2,
                       bounds.CenterPoint().y() - m::kExtensionIcon / 2,
                       m::kExtensionIcon, m::kExtensionIcon);
  if (item.icon.isNull()) {
    secondary::PaintGlyph(
        canvas, Glyph::kPuzzle, gfx::RectF(icon),
        Color(kGlyphLight, secondary::WithAlpha(SK_ColorWHITE, 0.85f)));
  } else {
    canvas->SaveLayerAlpha(item.enabled ? 255 : 90);
    secondary::DrawImageInRect(canvas, item.icon, icon);
    canvas->Restore();
  }
  if (!item.badge_text.empty()) {
    // Badge overlay at the icon's bottom-right (Chromium toolbar badge
    // convention; guess for size).
    const gfx::FontList font =
        secondary::FontOfSize(9, gfx::Font::Weight::BOLD);
    const int w = std::max(12, secondary::TextWidth(item.badge_text, font) + 6);
    const gfx::Rect badge(
        std::min(icon.right() + 4 - w / 2, bounds.right() - w - 2),
        icon.bottom() - 6, w, 12);
    secondary::FillRoundRect(canvas, gfx::RectF(badge), 6.f, item.badge_color);
    secondary::DrawText(canvas, item.badge_text, font, SK_ColorWHITE, badge,
                        gfx::Canvas::TEXT_ALIGN_CENTER);
  }
}

void OpenSiteControlView::PaintRowCircle(gfx::Canvas* canvas,
                                         const gfx::Rect& circle,
                                         bool on,
                                         Glyph glyph,
                                         bool in_use) {
  const SkColor disc = on ? Color(kCircleOnLight, kCircleOnDark)
                          : Color(secondary::WithAlpha(SK_ColorBLACK, 0.10f),
                                  secondary::WithAlpha(SK_ColorWHITE, 0.28f));
  secondary::FillRoundRect(canvas, gfx::RectF(circle), circle.width() / 2.f,
                           disc);
  // The glyph is a knock-out: drawn in the panel color on an "on" disc.
  const SkColor ink = on ? panel_color() : Color(kRowTitleLight, kRowTitleDark);
  const float g = m::kRowGlyph;
  secondary::PaintGlyph(canvas, glyph,
                        gfx::RectF(circle.CenterPoint().x() - g / 2.f,
                                   circle.CenterPoint().y() - g / 2.f, g, g),
                        ink);
  if (in_use) {
    const int d = m::kInUseDot;
    secondary::FillRoundRect(canvas,
                             gfx::RectF(circle.right() - d, circle.y(), d, d),
                             d / 2.f, SkColorSetRGB(0x34, 0xC7, 0x59));
  }
}

void OpenSiteControlView::PaintPermissionRow(size_t index,
                                             gfx::Canvas* canvas,
                                             const gfx::Rect& bounds,
                                             bool hovered) {
  if (index >= state_.permissions.size()) {
    return;
  }
  const SitePermissionRow& row = state_.permissions[index];
  PaintRowCircle(canvas,
                 gfx::Rect(bounds.x(), bounds.y(), m::kRowIcon, m::kRowIcon),
                 row.setting == SitePermissionSetting::kAllow,
                 PermissionGlyph(row.kind), row.in_use);
  const int text_x = bounds.x() + m::kRowTextX - m::kPadding;
  const int text_w = bounds.right() - text_x - 16;
  const gfx::FontList title =
      secondary::FontOfSize(kTitleFontSize, gfx::Font::Weight::SEMIBOLD);
  const gfx::FontList subtitle = secondary::FontOfSize(kSubtitleFontSize);
  secondary::DrawText(
      canvas, PermissionTitle(row.kind), title,
      Color(kRowTitleLight, kRowTitleDark),
      gfx::Rect(text_x, bounds.y() + m::kRowTitleBaseline - title.GetBaseline(),
                text_w, title.GetHeight()));
  secondary::DrawText(
      canvas, SettingLabel(row.setting), subtitle,
      Color(secondary::WithAlpha(kRowTitleLight, 0.6f), kRowSubtitleDark),
      gfx::Rect(text_x,
                bounds.y() + m::kRowSubtitleBaseline - subtitle.GetBaseline(),
                text_w, subtitle.GetHeight()));
  if (hovered) {
    // No row hover plate (SiteControlMetrics: rowGlyph note); show the
    // accessory chevron instead.
    secondary::PaintGlyph(
        canvas, Glyph::kChevronDown,
        gfx::RectF(bounds.right() - 14.f, bounds.CenterPoint().y() - 6.f, 12.f,
                   12.f),
        Color(secondary::WithAlpha(kRowTitleLight, 0.6f), kRowSubtitleDark));
  }
}

void OpenSiteControlView::PaintAdBlockRow(gfx::Canvas* canvas,
                                          const gfx::Rect& bounds,
                                          bool hovered) {
  PaintRowCircle(canvas,
                 gfx::Rect(bounds.x(), bounds.y(), m::kRowIcon, m::kRowIcon),
                 state_.ad_block_enabled, Glyph::kShield, false);
  const int text_x = bounds.x() + m::kRowTextX - m::kPadding;
  const int text_w = bounds.right() - text_x - 8;
  const gfx::FontList title =
      secondary::FontOfSize(kTitleFontSize, gfx::Font::Weight::SEMIBOLD);
  const gfx::FontList subtitle = secondary::FontOfSize(kSubtitleFontSize);
  secondary::DrawText(
      canvas, u"Ad Blocking", title, Color(kRowTitleLight, kRowTitleDark),
      gfx::Rect(text_x, bounds.y() + m::kRowTitleBaseline - title.GetBaseline(),
                text_w, title.GetHeight()));
  std::u16string detail;
  if (!state_.ad_block_enabled) {
    detail = u"Off on " + state_.host;
  } else {
    detail = base::NumberToString16(state_.ad_block_blocked_count) +
             u" blocked on " + state_.host;
  }
  secondary::DrawText(
      canvas, detail, subtitle,
      Color(secondary::WithAlpha(kRowTitleLight, 0.6f), kRowSubtitleDark),
      gfx::Rect(text_x,
                bounds.y() + m::kRowSubtitleBaseline - subtitle.GetBaseline(),
                text_w, subtitle.GetHeight()));
}

void OpenSiteControlView::PaintPill(gfx::Canvas* canvas,
                                    const gfx::Rect& bounds,
                                    bool hovered) {
  const gfx::RectF pill(bounds);
  secondary::FillRoundRect(
      canvas, pill, m::kPillRadius,
      state_.secure
          ? Color(secondary::WithAlpha(SK_ColorBLACK, hovered ? 0.07f : 0.04f),
                  secondary::WithAlpha(SK_ColorWHITE, hovered ? 0.08f : 0.05f))
          : Color(secondary::WithAlpha(SK_ColorBLACK, 0.05f),
                  secondary::WithAlpha(SK_ColorWHITE, 0.05f)));
  const SkColor ink = state_.secure
                          ? Color(kRowTitleLight, kRowTitleDark)
                          : Color(kInsecureTextLight, kInsecureTextDark);
  const float g = m::kPillLockGlyph;
  const gfx::RectF lock(bounds.x() + m::kPillPadding,
                        bounds.CenterPoint().y() - g / 2.f, g, g);
  secondary::PaintGlyph(canvas, state_.secure ? Glyph::kLock : Glyph::kShield,
                        lock, ink);
  const int text_x =
      bounds.x() + m::kPillPadding + m::kPillLockGlyph + m::kPillLockGap;
  secondary::DrawText(
      canvas, state_.secure ? state_.host : u"Not Secure",
      secondary::FontOfSize(kPillFontSize, gfx::Font::Weight::MEDIUM), ink,
      gfx::Rect(text_x, bounds.y(),
                std::max(0, bounds.right() - m::kPillPadding - text_x),
                bounds.height()));
}

void OpenSiteControlView::ShowPermissionMenu(size_t row_index) {
  if (row_index >= permission_rows_.size() ||
      (menu_runner_ && menu_runner_->IsRunning())) {
    return;
  }
  menu_row_ = row_index;
  menu_model_ = std::make_unique<ui::SimpleMenuModel>(this);
  menu_model_->AddRadioItem(kMenuAsk, u"Ask", kMenuGroup);
  menu_model_->AddRadioItem(kMenuAllow, u"Allow", kMenuGroup);
  menu_model_->AddRadioItem(kMenuBlock, u"Block", kMenuGroup);
  menu_runner_ = std::make_unique<views::MenuRunner>(
      menu_model_.get(), views::MenuRunner::NO_FLAGS);
  menu_runner_->RunMenuAt(
      GetWidget(), nullptr, permission_rows_[row_index]->GetBoundsInScreen(),
      views::MenuAnchorPosition::kTopLeft, ui::mojom::MenuSourceType::kMouse);
}

void OpenSiteControlView::ExecuteCommand(int command_id, int event_flags) {
  if (menu_row_ >= state_.permissions.size()) {
    return;
  }
  SitePermissionSetting setting = SitePermissionSetting::kAsk;
  if (command_id == kMenuAllow) {
    setting = SitePermissionSetting::kAllow;
  } else if (command_id == kMenuBlock) {
    setting = SitePermissionSetting::kBlock;
  }
  SitePermissionRow& row = state_.permissions[menu_row_];
  row.setting = setting;
  permission_rows_[menu_row_]->SchedulePaint();
  if (delegate_) {
    delegate_->OnSiteControlPermissionChanged(row.kind, setting);
  }
}

bool OpenSiteControlView::IsCommandIdChecked(int command_id) const {
  if (menu_row_ >= state_.permissions.size()) {
    return false;
  }
  switch (state_.permissions[menu_row_].setting) {
    case SitePermissionSetting::kAsk:
      return command_id == kMenuAsk;
    case SitePermissionSetting::kAllow:
      return command_id == kMenuAllow;
    case SitePermissionSetting::kBlock:
      return command_id == kMenuBlock;
  }
  return false;
}

BEGIN_METADATA(OpenSiteControlView)
END_METADATA

// --- OpenSiteControlBubble ---------------------------------------------------

OpenSiteControlBubble::OpenSiteControlBubble(SiteControlDelegate* delegate)
    : delegate_(delegate) {}

OpenSiteControlBubble::~OpenSiteControlBubble() {
  DiscardBubble(/*synchronous=*/true);
}

void OpenSiteControlBubble::DiscardBubble(bool synchronous) {
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
  // Posted in order: the widget is deleted before its delegate.
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

void OpenSiteControlBubble::Show(views::View* anchor,
                                 const SiteControlState& state,
                                 const secondary::Appearance& appearance) {
  // Reopening replaces the panel: release the old bubble (and cancel its
  // closed callback) before the members are reassigned.
  DiscardBubble(/*synchronous=*/false);
  bubble_delegate_ = std::make_unique<views::BubbleDialogDelegate>(
      anchor, views::BubbleBorder::TOP_LEFT, views::BubbleBorder::DIALOG_SHADOW,
      /*autosize=*/true);
  bubble_delegate_->set_margins(gfx::Insets());
  bubble_delegate_->set_fixed_width(site_control_metrics::kWidth);
  bubble_delegate_->set_corner_radius(site_control_metrics::kCornerRadius);
  bubble_delegate_->SetButtons(
      static_cast<int>(ui::mojom::DialogButton::kNone));
  bubble_delegate_->SetShowCloseButton(false);
  bubble_delegate_->SetShowTitle(false);
  bubble_delegate_->set_close_on_deactivate(true);
  contents_ = bubble_delegate_->SetContentsView(
      std::make_unique<OpenSiteControlView>(delegate_, state, appearance));
  bubble_delegate_->SetBackgroundColor(contents_->panel_color());
  widget_ = views::BubbleDialogDelegate::CreateBubble(
      bubble_delegate_.get(),
      base::BindOnce(&OpenSiteControlBubble::OnWidgetClosed,
                     weak_factory_.GetWeakPtr()));
  widget_->Show();
}

void OpenSiteControlBubble::Close() {
  if (widget_) {
    widget_->CloseWithReason(views::Widget::ClosedReason::kUnspecified);
  }
}

bool OpenSiteControlBubble::IsShowing() const {
  return widget_ && widget_->IsVisible();
}

void OpenSiteControlBubble::UpdateState(const SiteControlState& state) {
  if (contents_) {
    contents_->SetState(state);
  }
}

void OpenSiteControlBubble::SetAdBlockState(bool enabled, int blocked_count) {
  if (contents_) {
    contents_->SetAdBlockState(enabled, blocked_count);
  }
}

void OpenSiteControlBubble::OnWidgetClosed(views::Widget::ClosedReason reason) {
  // The close can start inside the widget's own activation handling, so hide
  // now and delete on the next task (widget first, then its delegate, which
  // must outlive it).
  DiscardBubble(/*synchronous=*/false);
  if (delegate_) {
    delegate_->OnSiteControlClosed();
  }
}

}  // namespace open_unified
