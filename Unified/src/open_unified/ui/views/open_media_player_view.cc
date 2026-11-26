// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_media_player_view.h"

#include <algorithm>
#include <cmath>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "cc/paint/paint_filter.h"
#include "cc/paint/paint_flags.h"
#include "open_unified/ui/design/open_glyphs.h"
#include "open_unified/ui/design/open_theme_shader.h"
#include "open_unified/ui/design/open_typography.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "ui/accessibility/ax_action_data.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/compositor/layer.h"
#include "ui/compositor/scoped_layer_animation_settings.h"
#include "ui/events/event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/animation/tween.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/text_elider.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/animation/bounds_animator.h"
#include "ui/views/controls/button/button.h"

namespace open_unified {

namespace mm = media_metrics;
using theme::Rgba;

namespace {

SkColor Sk(const Rgba& c) {
  return theme::ToSkColor(c);
}

SkColor WithOpacity(SkColor c, float opacity) {
  return SkColorSetA(c, static_cast<U8CPU>(std::lround(
                            std::clamp(opacity, 0.f, 1.f) * SkColorGetA(c))));
}

void FillRound(gfx::Canvas* canvas,
               const gfx::RectF& rect,
               float radius,
               SkColor color) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(color);
  canvas->DrawRoundRect(rect, radius, flags);
}

// Media control glyphs: SF Symbols on macOS (Icons.swift specs), Open's
// Skia shapes elsewhere.
enum class MediaGlyph {
  kPlay,
  kPause,
  kPrevious,
  kNext,
  kVolume,
  kVolumeMuted,
  kVolumeLow,
  kVolumeHigh,
  kPip,
  kClose,
};

struct MediaSymbol {
  const char* name;
  float point_size;
};

MediaSymbol SymbolFor(MediaGlyph glyph) {
  switch (glyph) {
    case MediaGlyph::kPlay:
      return {"play.fill", 14};
    case MediaGlyph::kPause:
      return {"pause.fill", 14};
    case MediaGlyph::kPrevious:
      return {"backward.end.fill", 14};
    case MediaGlyph::kNext:
      return {"forward.end.fill", 14};
    case MediaGlyph::kVolume:
      return {"speaker.wave.3.fill", 14};
    case MediaGlyph::kVolumeMuted:
      return {"speaker.slash.fill", 14};
    case MediaGlyph::kVolumeLow:
      return {"speaker.wave.1.fill", 12};
    case MediaGlyph::kVolumeHigh:
      return {"speaker.wave.3.fill", 12};
    case MediaGlyph::kPip:
      return {"pip", 12};
    case MediaGlyph::kClose:
      return {"xmark", 14};
  }
  return {"circle", 14};
}

void PaintSpeaker(gfx::Canvas* canvas,
                  const gfx::RectF& box,
                  SkColor color,
                  int waves,
                  bool muted) {
  cc::PaintFlags fill;
  fill.setAntiAlias(true);
  fill.setColor(color);
  const float cx = box.x() + box.width() * 0.32f;
  const float cy = box.CenterPoint().y();
  SkPathBuilder body;
  body.moveTo(box.x() + 1, cy - 2.5f);
  body.lineTo(cx - 1.5f, cy - 2.5f);
  body.lineTo(cx + 2.5f, cy - 6);
  body.lineTo(cx + 2.5f, cy + 6);
  body.lineTo(cx - 1.5f, cy + 2.5f);
  body.lineTo(box.x() + 1, cy + 2.5f);
  body.close();
  canvas->DrawPath(body.detach(), fill);
  cc::PaintFlags stroke;
  stroke.setAntiAlias(true);
  stroke.setColor(color);
  stroke.setStyle(cc::PaintFlags::kStroke_Style);
  stroke.setStrokeWidth(1.5f);
  stroke.setStrokeCap(cc::PaintFlags::kRound_Cap);
  if (muted) {
    const float x = cx + 5;
    canvas->DrawLine(gfx::PointF(x, cy - 3), gfx::PointF(x + 6, cy + 3),
                     stroke);
    canvas->DrawLine(gfx::PointF(x + 6, cy - 3), gfx::PointF(x, cy + 3),
                     stroke);
    return;
  }
  for (int i = 0; i < waves; ++i) {
    const float r = 3.5f + 2.8f * static_cast<float>(i);
    SkPathBuilder arc;
    arc.addArc(SkRect::MakeLTRB(cx + 1 - r, cy - r, cx + 1 + r, cy + r), -45,
               90);
    canvas->DrawPath(arc.detach(), stroke);
  }
}

void PaintFallbackGlyph(gfx::Canvas* canvas,
                        MediaGlyph glyph,
                        const gfx::RectF& bounds,
                        SkColor color) {
  gfx::RectF box = bounds;
  box.ClampToCenteredSize(gfx::SizeF(14, 14));
  cc::PaintFlags fill;
  fill.setAntiAlias(true);
  fill.setColor(color);
  const float cx = box.CenterPoint().x();
  const float cy = box.CenterPoint().y();
  switch (glyph) {
    case MediaGlyph::kPlay: {
      SkPathBuilder p;
      p.moveTo(cx - 4, cy - 6);
      p.lineTo(cx + 6, cy);
      p.lineTo(cx - 4, cy + 6);
      p.close();
      canvas->DrawPath(p.detach(), fill);
      return;
    }
    case MediaGlyph::kPause:
      canvas->DrawRoundRect(gfx::RectF(cx - 4.5f, cy - 6, 3, 12), 1, fill);
      canvas->DrawRoundRect(gfx::RectF(cx + 1.5f, cy - 6, 3, 12), 1, fill);
      return;
    case MediaGlyph::kPrevious:
    case MediaGlyph::kNext: {
      const float dir = glyph == MediaGlyph::kNext ? 1.f : -1.f;
      SkPathBuilder p;
      p.moveTo(cx - 5 * dir, cy - 5.5f);
      p.lineTo(cx + 4 * dir, cy);
      p.lineTo(cx - 5 * dir, cy + 5.5f);
      p.close();
      canvas->DrawPath(p.detach(), fill);
      const float bar_x = glyph == MediaGlyph::kNext ? cx + 4 : cx - 6;
      canvas->DrawRoundRect(gfx::RectF(bar_x, cy - 5.5f, 2, 11), 1, fill);
      return;
    }
    case MediaGlyph::kVolume:
    case MediaGlyph::kVolumeHigh:
      PaintSpeaker(canvas, box, color, 3, false);
      return;
    case MediaGlyph::kVolumeLow:
      PaintSpeaker(canvas, box, color, 1, false);
      return;
    case MediaGlyph::kVolumeMuted:
      PaintSpeaker(canvas, box, color, 0, true);
      return;
    case MediaGlyph::kPip: {
      cc::PaintFlags stroke = fill;
      stroke.setStyle(cc::PaintFlags::kStroke_Style);
      stroke.setStrokeWidth(1.5f);
      canvas->DrawRoundRect(gfx::RectF(cx - 7, cy - 5.5f, 14, 11), 2, stroke);
      canvas->DrawRoundRect(gfx::RectF(cx + 0.5f, cy + 0.5f, 5, 3.5f), 1,
                            fill);
      return;
    }
    case MediaGlyph::kClose:
      secondary::PaintGlyph(canvas, secondary::Glyph::kClose, box, color);
      return;
  }
}

void PaintMediaGlyph(gfx::Canvas* canvas,
                     MediaGlyph glyph,
                     const gfx::RectF& bounds,
                     SkColor color) {
  const MediaSymbol symbol = SymbolFor(glyph);
  if (!glyphs::DrawSystemSymbol(canvas, symbol.name, symbol.point_size,
                                glyphs::SymbolWeight::kMedium, bounds,
                                color)) {
    PaintFallbackGlyph(canvas, glyph, bounds, color);
  }
}

// Five slots spread across the card (MiniPlayerMetrics.slotX), rounded to
// whole points.
int SlotX(int k, int card_width) {
  const float x =
      mm::kSlotInset + static_cast<float>(k) *
                           static_cast<float>(card_width - 2 * mm::kSlotInset -
                                              mm::kButton) /
                           static_cast<float>(mm::kSlotCount - 1);
  return static_cast<int>(std::floor(x + 0.5f));
}

const gfx::FontList& TitleFont() {
  return typography::Make(mm::kTitleFontSize, gfx::Font::Weight::NORMAL);
}

}  // namespace

// ---------------------------------------------------------------------------
// MediaButton: a 24 pt glyph button with a 5 pt hover plate.

class OpenMiniPlayerCardView::MediaButton : public views::Button {
  METADATA_HEADER(MediaButton, views::Button)

 public:
  MediaButton(OpenMiniPlayerCardView* card, Control control)
      : views::Button(base::BindRepeating(&MediaButton::OnPressed,
                                          base::Unretained(this))),
        card_(card),
        control_(control) {
    SetFocusBehavior(FocusBehavior::ACCESSIBLE_ONLY);
  }

  void SetGlyph(MediaGlyph glyph) {
    if (glyph_ != glyph) {
      glyph_ = glyph;
      SchedulePaint();
    }
  }
  void SetName(const std::u16string& name) {
    if (name_ == name) {
      return;
    }
    name_ = name;
    SetTooltipText(control_ == Control::kFavicon ? std::u16string() : name);
    GetViewAccessibility().SetName(name);
  }

  void PaintButtonContents(gfx::Canvas* canvas) override {
    const gfx::RectF b(GetLocalBounds());
    const bool enabled = GetEnabled();
    const bool hovered =
        enabled && (GetState() == STATE_HOVERED || GetState() == STATE_PRESSED);
    if (hovered) {
      const bool dark = card_->IsDark();
      FillRound(canvas, b, mm::kButtonPlateRadius,
                dark ? SkColorSetARGB(0x14, 0xFF, 0xFF, 0xFF)
                     : SkColorSetARGB(0x12, 0x00, 0x00, 0x00));
    }
    if (control_ == Control::kFavicon) {
      const gfx::ImageSkia icon = card_->Favicon();
      const gfx::Rect slot(4, 4, mm::kFaviconSize, mm::kFaviconSize);
      if (!icon.isNull()) {
        secondary::DrawImageInRect(canvas, icon, slot);
      } else {
        // No favicon or artwork: a letter tile of the host.
        const OpenMediaSessionState& s = card_->session();
        glyphs::DrawLetterTile(
            canvas, gfx::RectF(slot),
            base::UTF8ToUTF16(s.source_host.empty() ? s.title : s.source_host),
            card_->GlyphColor(true), SK_ColorWHITE);
      }
      return;
    }
    PaintMediaGlyph(canvas, glyph_, b, card_->GlyphColor(enabled));
  }

 private:
  void OnPressed(const ui::Event& event) { card_->OnControl(control_); }

  raw_ptr<OpenMiniPlayerCardView> card_;
  Control control_;
  MediaGlyph glyph_ = MediaGlyph::kPlay;
  std::u16string name_;
};

// ---------------------------------------------------------------------------
// VolumeSlider: 4 pt track, 12 pt knob, 0.05 steps (MediaVolumeSlider).

class OpenMiniPlayerCardView::VolumeSlider : public views::View {
  METADATA_HEADER(VolumeSlider, views::View)

 public:
  explicit VolumeSlider(OpenMiniPlayerCardView* card) : card_(card) {
    SetFocusBehavior(FocusBehavior::ACCESSIBLE_ONLY);
    GetViewAccessibility().SetRole(ax::mojom::Role::kSlider);
    GetViewAccessibility().SetName(u"Tab Volume");
  }

  void SetValue(float value) {
    value = std::clamp(value, 0.f, 1.f);
    if (value_ == value) {
      return;
    }
    value_ = value;
    GetViewAccessibility().SetValue(
        base::NumberToString16(static_cast<int>(std::lround(value_ * 100))) +
        u"%");
    SchedulePaint();
  }
  float value() const { return value_; }

  void OnPaint(gfx::Canvas* canvas) override {
    const float knob = mm::kDrawerKnob;
    const float mid = height() / 2.f;
    const gfx::RectF track(0, mid - mm::kDrawerTrackHeight / 2.f, width(),
                           mm::kDrawerTrackHeight);
    FillRound(canvas, track, mm::kDrawerTrackRadius, card_->GlyphColor(false));
    const float x = knob / 2 + value_ * std::max(0.f, width() - knob);
    gfx::RectF filled = track;
    filled.set_width(x);
    FillRound(canvas, filled, mm::kDrawerTrackRadius, card_->GlyphColor(true));
    // Knob: white with a 2 pt soft shadow 1 pt down.
    cc::PaintFlags shadow;
    shadow.setAntiAlias(true);
    shadow.setColor(SkColorSetARGB(0x33, 0, 0, 0));
    shadow.setImageFilter(sk_make_sp<cc::BlurPaintFilter>(
        1.f, 1.f, SkTileMode::kDecal, nullptr));
    canvas->DrawCircle(gfx::PointF(x, mid + 1), knob / 2, shadow);
    cc::PaintFlags flags;
    flags.setAntiAlias(true);
    flags.setColor(SK_ColorWHITE);
    canvas->DrawCircle(gfx::PointF(x, mid), knob / 2, flags);
  }

  bool OnMousePressed(const ui::MouseEvent& event) override {
    Change(event.location().x());
    return true;
  }
  bool OnMouseDragged(const ui::MouseEvent& event) override {
    Change(event.location().x());
    return true;
  }
  void OnMouseReleased(const ui::MouseEvent& event) override {
    Change(event.location().x());
  }
  bool OnKeyPressed(const ui::KeyEvent& event) override {
    if (event.key_code() == ui::VKEY_RIGHT || event.key_code() == ui::VKEY_UP) {
      Commit(value_ + mm::kVolumeStep);
      return true;
    }
    if (event.key_code() == ui::VKEY_LEFT ||
        event.key_code() == ui::VKEY_DOWN) {
      Commit(value_ - mm::kVolumeStep);
      return true;
    }
    return false;
  }
  bool HandleAccessibleAction(const ui::AXActionData& action) override {
    if (action.action == ax::mojom::Action::kIncrement) {
      Commit(value_ + mm::kVolumeStep);
      return true;
    }
    if (action.action == ax::mojom::Action::kDecrement) {
      Commit(value_ - mm::kVolumeStep);
      return true;
    }
    return views::View::HandleAccessibleAction(action);
  }

 private:
  void Change(int x) {
    const float knob = mm::kDrawerKnob;
    const float span = std::max(1.f, width() - knob);
    const float raw = (static_cast<float>(x) - knob / 2) / span;
    Commit(std::round(raw / mm::kVolumeStep) * mm::kVolumeStep);
  }
  void Commit(float value) {
    value = std::clamp(value, 0.f, 1.f);
    if (value == value_) {
      return;
    }
    SetValue(value);
    card_->SetVolume(value_);
  }

  raw_ptr<OpenMiniPlayerCardView> card_;
  float value_ = -1;
};

// ---------------------------------------------------------------------------
// OpenMiniPlayerCardView

OpenMiniPlayerCardView::OpenMiniPlayerCardView(
    OpenMediaPlayerStackView* stack,
    const OpenMediaSessionState& session)
    : stack_(stack), session_(session) {
  SetPaintToLayer();
  layer()->SetFillsBoundsOpaquely(false);
  GetViewAccessibility().SetRole(ax::mojom::Role::kGroup,
                                 u"media controls");
  for (Control c : {Control::kFavicon, Control::kPrevious, Control::kPlayPause,
                    Control::kNext, Control::kVolume, Control::kPip,
                    Control::kClose, Control::kVolumeLow,
                    Control::kVolumeHigh}) {
    buttons_[c] = AddButton(c);
  }
  slider_ = AddChildView(std::make_unique<VolumeSlider>(this));
  SyncControls();
}

OpenMiniPlayerCardView::~OpenMiniPlayerCardView() = default;

OpenMiniPlayerCardView::MediaButton* OpenMiniPlayerCardView::AddButton(
    Control control) {
  return AddChildView(std::make_unique<MediaButton>(this, control));
}

void OpenMiniPlayerCardView::SetSession(const OpenMediaSessionState& session) {
  session_ = session;
  SyncControls();
  SchedulePaint();
}

void OpenMiniPlayerCardView::Configure(bool expanded, size_t level) {
  const bool changed = expanded_ != expanded;
  expanded_ = expanded;
  level_ = level;
  if (changed && !expanded_) {
    title_hovered_ = false;
  }
  // Collapsed, only the front card takes input.
  SetCanProcessEventsWithinSubtree(expanded_ || level_ == 0);
  SyncControls();
  if (changed) {
    InvalidateLayout();
    SchedulePaint();
  }
}

bool OpenMiniPlayerCardView::drawer_open() const {
  return expanded_ && stack_->drawers_.contains(session_.tab_id);
}

int OpenMiniPlayerCardView::CardHeight() const {
  if (!expanded_) {
    return mm::kRowHeight;
  }
  return (drawer_open() ? 3 : 2) * mm::kRowHeight;
}

void OpenMiniPlayerCardView::Retheme() {
  SchedulePaint();
  for (views::View* child : children()) {
    child->SchedulePaint();
  }
}

bool OpenMiniPlayerCardView::IsDark() const {
  return stack_->theme_.appearance == theme::ContentAppearance::kDark;
}

// SidebarRole.mediaControlGlyph (accessoryForeground: black 0.50 / white
// 0.66) and mediaControlGlyphDisabled (black 0.17 / white 0.22).
SkColor OpenMiniPlayerCardView::GlyphColor(bool enabled) const {
  if (IsDark()) {
    return enabled ? SkColorSetARGB(0xA8, 0xFF, 0xFF, 0xFF)
                   : SkColorSetARGB(0x38, 0xFF, 0xFF, 0xFF);
  }
  return enabled ? SkColorSetARGB(0x80, 0x00, 0x00, 0x00)
                 : SkColorSetARGB(0x2B, 0x00, 0x00, 0x00);
}

// SidebarRole.miniPlayerTitle (Core.foregroundPrimary: #0E0F10 at 0.90 /
// white 0.80).
SkColor OpenMiniPlayerCardView::TitleColor() const {
  return IsDark() ? SkColorSetARGB(0xCC, 0xFF, 0xFF, 0xFF)
                  : SkColorSetARGB(0xE6, 0x0E, 0x0F, 0x10);
}

gfx::ImageSkia OpenMiniPlayerCardView::Favicon() const {
  if (stack_->callbacks_.favicon_for) {
    gfx::ImageSkia icon = stack_->callbacks_.favicon_for.Run(session_.tab_id);
    if (!icon.isNull()) {
      return icon;
    }
  }
  return session_.artwork;
}

void OpenMiniPlayerCardView::SyncControls() {
  const bool playing = session_.is_playing;
  MediaButton* play = buttons_[Control::kPlayPause];
  play->SetGlyph(playing ? MediaGlyph::kPause : MediaGlyph::kPlay);
  play->SetName(playing ? u"Pause" : u"Play");
  play->SetEnabled(session_.can_play_pause || session_.is_controllable);

  buttons_[Control::kFavicon]->SetName(u"Back to Tab");
  buttons_[Control::kPrevious]->SetGlyph(MediaGlyph::kPrevious);
  buttons_[Control::kPrevious]->SetName(u"Previous Track");
  buttons_[Control::kPrevious]->SetEnabled(session_.can_previous);
  buttons_[Control::kNext]->SetGlyph(MediaGlyph::kNext);
  buttons_[Control::kNext]->SetName(u"Next Track");
  buttons_[Control::kNext]->SetEnabled(session_.can_next);
  buttons_[Control::kVolume]->SetGlyph(session_.is_muted
                                           ? MediaGlyph::kVolumeMuted
                                           : MediaGlyph::kVolume);
  buttons_[Control::kVolume]->SetName(u"Adjust Tab Volume");
  buttons_[Control::kPip]->SetGlyph(MediaGlyph::kPip);
  buttons_[Control::kPip]->SetName(session_.in_pip
                                       ? u"Close Picture in Picture"
                                       : u"Open Picture in Picture");
  buttons_[Control::kClose]->SetGlyph(MediaGlyph::kClose);
  buttons_[Control::kClose]->SetName(u"Close Mini Player");
  buttons_[Control::kVolumeLow]->SetGlyph(MediaGlyph::kVolumeLow);
  buttons_[Control::kVolumeLow]->SetName(session_.is_muted ? u"Unmute"
                                                           : u"Mute");
  buttons_[Control::kVolumeHigh]->SetGlyph(MediaGlyph::kVolumeHigh);
  buttons_[Control::kVolumeHigh]->SetName(u"Set Tab Volume to 100%");

  // The title row shows only expanded; Picture in Picture only for video.
  const bool pip = session_.has_video || session_.pip_available;
  buttons_[Control::kPip]->SetVisible(expanded_ && pip);
  buttons_[Control::kClose]->SetVisible(expanded_);
  const bool drawer = drawer_open();
  buttons_[Control::kVolumeLow]->SetVisible(drawer);
  buttons_[Control::kVolumeHigh]->SetVisible(drawer);
  slider_->SetVisible(drawer);
  slider_->SetValue(session_.is_muted ? 0.f : session_.volume);

  const std::u16string title = base::UTF8ToUTF16(
      session_.title.empty() ? session_.source_host : session_.title);
  std::u16string label = title;
  if (!session_.artist.empty()) {
    label += u", " + base::UTF8ToUTF16(session_.artist);
  }
  if (!session_.source_host.empty() && !session_.title.empty()) {
    label += u", " + base::UTF8ToUTF16(session_.source_host);
  }
  label += session_.is_muted ? u", Muted"
                             : (playing ? u", Playing" : u", Paused");
  GetViewAccessibility().SetName(label);
}

void OpenMiniPlayerCardView::OnControl(Control control) {
  const OpenMediaPlayerStackView::Callbacks& cb = stack_->callbacks_;
  const ItemID id = session_.tab_id;
  auto run = [&id](const OpenMediaPlayerStackView::TabCallback& callback) {
    if (callback) {
      callback.Run(id);
    }
  };
  switch (control) {
    case Control::kFavicon:
      run(cb.on_focus_tab);
      return;
    case Control::kPrevious:
      run(cb.on_previous);
      return;
    case Control::kPlayPause:
      run(cb.on_toggle_play_pause);
      return;
    case Control::kNext:
      run(cb.on_next);
      return;
    case Control::kVolume:
      // Expanded: the volume drawer; collapsed (keyboard): mute.
      if (expanded_) {
        ToggleDrawer();
      } else {
        run(cb.on_toggle_mute);
      }
      return;
    case Control::kPip:
      run(cb.on_toggle_pip);
      return;
    case Control::kClose:
      run(cb.on_dismiss);
      return;
    case Control::kVolumeLow:
      run(cb.on_toggle_mute);
      return;
    case Control::kVolumeHigh:
      SetVolume(1.f);
      return;
  }
}

void OpenMiniPlayerCardView::ToggleDrawer() {
  std::set<ItemID>& drawers = stack_->drawers_;
  if (!drawers.erase(session_.tab_id)) {
    drawers.insert(session_.tab_id);
  }
  SyncControls();
  stack_->OnCardHeightChanged();
}

void OpenMiniPlayerCardView::SetVolume(float volume) {
  slider_->SetValue(volume);
  if (stack_->callbacks_.on_set_volume) {
    stack_->callbacks_.on_set_volume.Run(session_.tab_id, volume);
  }
}

bool OpenMiniPlayerCardView::TitleRowContains(const gfx::Point& point) const {
  return expanded_ && point.y() >= 0 && point.y() < mm::kRowHeight;
}

void OpenMiniPlayerCardView::SetTitleHovered(bool hovered) {
  if (title_hovered_ != hovered) {
    title_hovered_ = hovered;
    SchedulePaint();
  }
}

void OpenMiniPlayerCardView::Layout(PassKey) {
  const int w = width();
  const int h = height();
  // Rows keep their place from the bottom; the card's top edge reveals them.
  const int controls_y = h - mm::kRowHeight;
  const int drawer_y = h - 2 * mm::kRowHeight;
  const int title_y = h - CardHeight();
  const Control slots[] = {Control::kFavicon, Control::kPrevious,
                           Control::kPlayPause, Control::kNext,
                           Control::kVolume};
  for (int k = 0; k < mm::kSlotCount; ++k) {
    buttons_[slots[k]]->SetBounds(SlotX(k, w), controls_y + mm::kButtonY,
                                  mm::kButton, mm::kButton);
  }
  buttons_[Control::kClose]->SetBounds(w - mm::kCloseTrailing,
                                       title_y + mm::kButtonY, mm::kButton,
                                       mm::kButton);
  buttons_[Control::kPip]->SetBounds(w - mm::kPipTrailing,
                                     title_y + mm::kButtonY, mm::kButton,
                                     mm::kButton);
  buttons_[Control::kVolumeLow]->SetBounds(
      mm::kSlotInset, drawer_y + mm::kButtonY, mm::kButton, mm::kButton);
  buttons_[Control::kVolumeHigh]->SetBounds(
      w - mm::kCloseTrailing, drawer_y + mm::kButtonY, mm::kButton,
      mm::kButton);
  slider_->SetBounds(mm::kDrawerSliderInset, drawer_y,
                     std::max(0, w - 2 * mm::kDrawerSliderInset),
                     mm::kRowHeight);
}

void OpenMiniPlayerCardView::OnPaint(gfx::Canvas* canvas) {
  const OpenSpaceThemeState& theme = stack_->theme_;
  FillRound(canvas, gfx::RectF(GetLocalBounds()), mm::kCornerRadius,
            Sk(theme.style.MiniPlayerFill(theme.appearance)));
  if (!expanded_) {
    return;
  }
  // Title row: the tab's media title, "Back to Tab" while hovered.
  const int w = width();
  const int title_y = height() - CardHeight();
  const bool pip = session_.has_video || session_.pip_available;
  const int right = w - (pip ? mm::kPipTrailing : mm::kCloseTrailing) -
                    mm::kTitleGap;
  const gfx::FontList& font = TitleFont();
  const int top = title_y + typography::TextTopForBaseline(
                                font, static_cast<float>(mm::kTitleBaseline));
  const std::u16string text =
      title_hovered_ ? u"Back to Tab"
                     : base::UTF8ToUTF16(session_.title.empty()
                                             ? session_.source_host
                                             : session_.title);
  const int text_w = std::max(0, right - mm::kTitleX);
  if (text_w > 0 && !text.empty()) {
    canvas->DrawStringRectWithFlags(
        gfx::ElideText(text, font, text_w, gfx::ELIDE_TAIL), font,
        TitleColor(), gfx::Rect(mm::kTitleX, top, text_w, font.GetHeight()),
        gfx::Canvas::TEXT_ALIGN_LEFT | gfx::Canvas::NO_SUBPIXEL_RENDERING);
  }
}

bool OpenMiniPlayerCardView::OnMousePressed(const ui::MouseEvent& event) {
  pressed_ = event.IsOnlyLeftMouseButton();
  return pressed_;
}

void OpenMiniPlayerCardView::OnMouseReleased(const ui::MouseEvent& event) {
  const bool pressed = pressed_;
  pressed_ = false;
  if (pressed && GetLocalBounds().Contains(event.location()) &&
      stack_->callbacks_.on_focus_tab) {
    stack_->callbacks_.on_focus_tab.Run(session_.tab_id);
  }
}

void OpenMiniPlayerCardView::OnMouseMoved(const ui::MouseEvent& event) {
  SetTitleHovered(TitleRowContains(event.location()));
}

void OpenMiniPlayerCardView::OnMouseExited(const ui::MouseEvent& event) {
  SetTitleHovered(false);
}

BEGIN_METADATA(OpenMiniPlayerCardView, MediaButton)
END_METADATA

BEGIN_METADATA(OpenMiniPlayerCardView, VolumeSlider)
END_METADATA

BEGIN_METADATA(OpenMiniPlayerCardView)
END_METADATA

// ---------------------------------------------------------------------------
// OpenMediaPlayerStackView

OpenMediaPlayerStackView::Callbacks::Callbacks() = default;
OpenMediaPlayerStackView::Callbacks::Callbacks(const Callbacks&) = default;
OpenMediaPlayerStackView::Callbacks&
OpenMediaPlayerStackView::Callbacks::operator=(const Callbacks&) = default;
OpenMediaPlayerStackView::Callbacks::~Callbacks() = default;

OpenMediaPlayerStackView::OpenMediaPlayerStackView(Callbacks callbacks)
    : callbacks_(std::move(callbacks)),
      animator_(std::make_unique<views::BoundsAnimator>(this)) {
  SetNotifyEnterExitOnChild(true);
  animator_->SetAnimationDuration(mm::kStackMotion);
  animator_->set_tween_type(gfx::Tween::EASE_OUT);
  GetViewAccessibility().SetRole(ax::mojom::Role::kGroup);
  GetViewAccessibility().SetName(u"Media");
}

OpenMediaPlayerStackView::~OpenMediaPlayerStackView() {
  collapse_timer_.Stop();
  animator_->Cancel();
}

OpenMiniPlayerCardView* OpenMediaPlayerStackView::card_at(
    size_t index) const {
  return index < cards_.size() ? cards_[index].get() : nullptr;
}

void OpenMediaPlayerStackView::SetAnimationsEnabled(bool enabled) {
  animations_enabled_ = enabled;
  if (!enabled) {
    animator_->Cancel();
  }
}

void OpenMediaPlayerStackView::SetTheme(const OpenSpaceThemeState& theme) {
  theme_ = theme;
  SchedulePaint();
  for (OpenMiniPlayerCardView* card : cards_) {
    card->Retheme();
  }
}

void OpenMediaPlayerStackView::UpdateSessions(
    std::vector<OpenMediaSessionState> sessions,
    const OpenSpaceThemeState& theme) {
  theme_ = theme;
  std::erase_if(sessions,
                [](const OpenMediaSessionState& s) { return s.dismissed; });

  std::map<ItemID, raw_ptr<OpenMiniPlayerCardView>> existing;
  for (OpenMiniPlayerCardView* card : cards_) {
    existing[card->tab_id()] = card;
  }
  std::vector<raw_ptr<OpenMiniPlayerCardView>> next;
  bool structure_changed = sessions.size() != cards_.size();
  for (size_t i = 0; i < sessions.size(); ++i) {
    const OpenMediaSessionState& session = sessions[i];
    auto it = existing.find(session.tab_id);
    OpenMiniPlayerCardView* card = nullptr;
    if (it != existing.end()) {
      card = it->second;
      existing.erase(it);
      card->SetSession(session);
      card->Retheme();
    } else {
      card = AddChildView(
          std::make_unique<OpenMiniPlayerCardView>(this, session));
      structure_changed = true;
    }
    if (i >= cards_.size() || cards_[i] != card) {
      structure_changed = true;
    }
    next.push_back(card);
  }
  // Remove cards whose session ended (drop raw_ptrs before deleting).
  cards_.clear();
  for (auto& [id, card] : existing) {
    drawers_.erase(id);
    OpenMiniPlayerCardView* view = card.get();
    card = nullptr;
    animator_->StopAnimatingView(view);
    RemoveChildViewT(view);
  }
  cards_ = std::move(next);
  // Front card last in z-order (painted on top).
  for (size_t i = 0; i < cards_.size(); ++i) {
    ReorderChildView(cards_[i].get(), cards_.size() - 1 - i);
  }
  if (cards_.empty()) {
    expanded_ = false;
    collapse_timer_.Stop();
  }
  Remeasure(/*animate=*/!structure_changed);
}

int OpenMediaPlayerStackView::StackHeight() const {
  if (cards_.empty()) {
    return 0;
  }
  if (expanded_) {
    int height = 0;
    for (OpenMiniPlayerCardView* card : cards_) {
      height += card->CardHeight();
    }
    return height + static_cast<int>(cards_.size() - 1) * mm::kExpandedGap;
  }
  return cards_.front()->CardHeight() +
         static_cast<int>(cards_.size() - 1) * mm::kStackOffset;
}

gfx::Size OpenMediaPlayerStackView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  const int stack = StackHeight();
  return gfx::Size(0, stack == 0 ? 0 : mm::kGapAbove + stack);
}

void OpenMediaPlayerStackView::SetExpanded(bool expanded) {
  if (cards_.empty()) {
    expanded = false;
  }
  if (expanded_ == expanded) {
    return;
  }
  expanded_ = expanded;
  if (!expanded_) {
    // A collapsed card has no drawer.
    for (OpenMiniPlayerCardView* card : cards_) {
      drawers_.erase(card->tab_id());
    }
  }
  Remeasure(/*animate=*/true);
}

void OpenMediaPlayerStackView::Collapse() {
  if (!hovered_) {
    SetExpanded(false);
  }
}

void OpenMediaPlayerStackView::OnCardHeightChanged() {
  Remeasure(/*animate=*/true);
}

void OpenMediaPlayerStackView::Remeasure(bool animate) {
  for (size_t i = 0; i < cards_.size(); ++i) {
    cards_[i]->Configure(expanded_, i);
  }
  animate_next_layout_ = animate && animations_enabled_ && GetWidget() &&
                         GetWidget()->IsVisible();
  PreferredSizeChanged();
  InvalidateLayout();
  SchedulePaint();
}

float OpenMediaPlayerStackView::TargetOpacity(size_t level) const {
  if (expanded_) {
    return 1.f;
  }
  return std::max(0.f, 1.f - static_cast<float>(level) * mm::kStackOpacityStep);
}

std::vector<gfx::Rect> OpenMediaPlayerStackView::TargetBounds() const {
  std::vector<gfx::Rect> out;
  const int required = height();
  int accumulated = 0;
  for (size_t i = 0; i < cards_.size(); ++i) {
    const int card_h = cards_[i]->CardHeight();
    accumulated += card_h;
    const int level = static_cast<int>(i);
    const int inset = mm::kInset + (expanded_ ? 0 : level * mm::kStackInset);
    const int y = expanded_
                      ? required - accumulated - level * mm::kExpandedGap
                      : required - mm::kRowHeight - level * mm::kStackOffset;
    out.emplace_back(inset, y, std::max(0, width() - 2 * inset), card_h);
  }
  return out;
}

void OpenMediaPlayerStackView::Layout(PassKey) {
  const std::vector<gfx::Rect> targets = TargetBounds();
  const bool animate = animate_next_layout_;
  animate_next_layout_ = false;
  // The stack grows upward: keep each card where it is on screen before
  // animating it to its new place.
  const int delta = height() - last_height_;
  last_height_ = height();
  for (size_t i = 0; i < cards_.size(); ++i) {
    OpenMiniPlayerCardView* card = cards_[i];
    const gfx::Rect current = card->bounds();
    const float opacity = TargetOpacity(i);
    if (animate && !current.IsEmpty()) {
      gfx::Rect from = current;
      from.Offset(0, delta);
      animator_->StopAnimatingView(card);
      card->SetBoundsRect(from);
      animator_->AnimateViewTo(card, targets[i]);
      ui::ScopedLayerAnimationSettings settings(card->layer()->GetAnimator());
      settings.SetTransitionDuration(mm::kStackMotion);
      settings.SetTweenType(gfx::Tween::EASE_OUT);
      card->layer()->SetOpacity(opacity);
    } else {
      animator_->StopAnimatingView(card);
      card->SetBoundsRect(targets[i]);
      card->layer()->SetOpacity(opacity);
    }
  }
}

void OpenMediaPlayerStackView::OnPaint(gfx::Canvas* canvas) {
  // Card shadows (black 0.21, radius 4, no offset) under every card.
  for (size_t i = cards_.size(); i > 0; --i) {
    OpenMiniPlayerCardView* card = cards_[i - 1];
    if (card->bounds().IsEmpty()) {
      continue;
    }
    cc::PaintFlags flags;
    flags.setAntiAlias(true);
    flags.setColor(WithOpacity(SK_ColorBLACK,
                               mm::kShadowOpacity * TargetOpacity(i - 1)));
    flags.setImageFilter(sk_make_sp<cc::BlurPaintFilter>(
        mm::kShadowRadius / 2, mm::kShadowRadius / 2, SkTileMode::kDecal,
        nullptr));
    canvas->DrawRoundRect(gfx::RectF(card->bounds()), mm::kCornerRadius,
                          flags);
  }
}

void OpenMediaPlayerStackView::OnMouseEntered(const ui::MouseEvent& event) {
  hovered_ = true;
  collapse_timer_.Stop();
  SetExpanded(true);
}

void OpenMediaPlayerStackView::OnMouseExited(const ui::MouseEvent& event) {
  hovered_ = false;
  if (!expanded_) {
    return;
  }
  collapse_timer_.Start(FROM_HERE, mm::kCollapseDelay,
                        base::BindOnce(&OpenMediaPlayerStackView::Collapse,
                                       base::Unretained(this)));
}

void OpenMediaPlayerStackView::VisibilityChanged(views::View* starting_from,
                                                 bool is_visible) {
  if (is_visible) {
    return;
  }
  // Hidden: no pending collapse, no running motion.
  collapse_timer_.Stop();
  hovered_ = false;
  animator_->Cancel();
  if (expanded_) {
    expanded_ = false;
    drawers_.clear();
    Remeasure(/*animate=*/false);
  }
}

BEGIN_METADATA(OpenMediaPlayerStackView)
END_METADATA

}  // namespace open_unified
