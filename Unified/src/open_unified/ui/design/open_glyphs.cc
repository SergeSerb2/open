// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/design/open_glyphs.h"

#include <algorithm>
#include <cmath>

#include "base/strings/utf_string_conversions.h"
#include "cc/paint/color_filter.h"
#include "cc/paint/paint_canvas.h"
#include "cc/paint/paint_flags.h"
#include "open_unified/ui/design/open_typography.h"
#include "third_party/skia/include/core/SkPath.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "third_party/skia/include/core/SkRRect.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/rect_conversions.h"
#include "ui/gfx/geometry/skia_conversions.h"
#include "ui/gfx/scoped_canvas.h"

namespace open_unified::glyphs {

namespace {

cc::PaintFlags Stroke(SkColor color, float width) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setStyle(cc::PaintFlags::kStroke_Style);
  flags.setStrokeWidth(width);
  flags.setStrokeCap(cc::PaintFlags::kRound_Cap);
  flags.setStrokeJoin(cc::PaintFlags::kRound_Join);
  flags.setColor(color);
  return flags;
}

cc::PaintFlags Fill(SkColor color) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setStyle(cc::PaintFlags::kFill_Style);
  flags.setColor(color);
  return flags;
}

SkRRect RRect(float x, float y, float w, float h, float r) {
  return SkRRect::MakeRectXY(SkRect::MakeXYWH(x, y, w, h), r, r);
}

void Line(gfx::Canvas* canvas,
          float x0,
          float y0,
          float x1,
          float y1,
          const cc::PaintFlags& flags) {
  SkPathBuilder b;
  b.moveTo(x0, y0);
  b.lineTo(x1, y1);
  canvas->DrawPath(b.detach(), flags);
}

void Polyline(gfx::Canvas* canvas,
              std::initializer_list<SkPoint> points,
              const cc::PaintFlags& flags,
              bool close = false) {
  SkPathBuilder b;
  bool first = true;
  for (const SkPoint& p : points) {
    if (first) {
      b.moveTo(p);
      first = false;
    } else {
      b.lineTo(p);
    }
  }
  if (close) {
    b.close();
  }
  canvas->DrawPath(b.detach(), flags);
}

void Circle(gfx::Canvas* canvas,
            float cx,
            float cy,
            float r,
            const cc::PaintFlags& flags) {
  canvas->sk_canvas()->drawOval(SkRect::MakeLTRB(cx - r, cy - r, cx + r, cy + r),
                                flags);
}

void Arc(gfx::Canvas* canvas,
         float cx,
         float cy,
         float r,
         float start_degrees,
         float sweep_degrees,
         const cc::PaintFlags& flags) {
  SkPathBuilder b;
  b.arcTo(SkRect::MakeLTRB(cx - r, cy - r, cx + r, cy + r), start_degrees,
          sweep_degrees, /*forceMoveTo=*/true);
  canvas->DrawPath(b.detach(), flags);
}

void DrawSpeakerBody(gfx::Canvas* canvas, const cc::PaintFlags& flags) {
  Polyline(canvas,
           {{0.7f, 3.8f},
            {3.6f, 3.8f},
            {7.2f, 0.8f},
            {7.2f, 10.2f},
            {3.6f, 7.2f},
            {0.7f, 7.2f}},
           flags, /*close=*/true);
}

}  // namespace

gfx::SizeF InkSize(Glyph glyph) {
  switch (glyph) {
    case Glyph::kSidebarToggle:
      return {19, 15};
    case Glyph::kBack:
    case Glyph::kForward:
      return {15, 12};
    case Glyph::kReload:
      return {14, 17};
    case Glyph::kStop:
      return {11, 11};
    case Glyph::kMore:
      return {16, 4};
    case Glyph::kMagnifier:
      return {12, 12};
    case Glyph::kLink:
      return {15, 14};
    case Glyph::kSiteControls:
      return {16, 16};
    case Glyph::kPlus:
      return {11, 11};
    case Glyph::kBottomPlus:
      return {14, 14};
    case Glyph::kClose:
      return {10, 10};
    case Glyph::kMinus:
      return {14, 2};
    case Glyph::kChevronDown:
      return {9, 5.5f};
    case Glyph::kChevronRight:
      return {5.5f, 9};
    case Glyph::kArrowDown:
      return {8, 9};
    case Glyph::kSpeaker:
      return {15, 11};
    case Glyph::kSpeakerMuted:
      return {14, 12};
    case Glyph::kLibrary:
      return {14, 16};
    case Glyph::kFolderClosed:
    case Glyph::kFolderOpen:
      return {18, 14};
    case Glyph::kPlanet:
      return {14, 14};
    case Glyph::kWindowClose:
    case Glyph::kWindowMinimize:
    case Glyph::kWindowZoom:
      return {6, 6};
    case Glyph::kPuzzle:
      return {14, 14};
  }
  return {12, 12};
}

void Draw(gfx::Canvas* canvas,
          Glyph glyph,
          const gfx::RectF& bounds,
          SkColor color,
          gfx::Vector2dF offset) {
  const gfx::SizeF ink = InkSize(glyph);
  const float ox = bounds.x() + (bounds.width() - ink.width()) / 2 + offset.x();
  const float oy =
      bounds.y() + (bounds.height() - ink.height()) / 2 + offset.y();
  gfx::ScopedCanvas scoped(canvas);
  canvas->sk_canvas()->translate(ox, oy);

  switch (glyph) {
    case Glyph::kSidebarToggle: {
      const cc::PaintFlags pen = Stroke(color, 1.4f);
      canvas->sk_canvas()->drawRRect(RRect(0.7f, 0.7f, 17.6f, 13.6f, 3.2f),
                                     pen);
      Line(canvas, 6.6f, 0.7f, 6.6f, 14.3f, pen);
      const cc::PaintFlags fine = Stroke(color, 1.2f);
      for (float y : {4.0f, 6.5f, 9.0f}) {
        Line(canvas, 2.6f, y, 4.4f, y, fine);
      }
      break;
    }
    case Glyph::kBack:
    case Glyph::kForward: {
      const bool back = glyph == Glyph::kBack;
      auto x = [&](float v) { return back ? v : 15.0f - v; };
      const cc::PaintFlags pen = Stroke(color, 1.5f);
      Line(canvas, x(1.0f), 6.0f, x(14.2f), 6.0f, pen);
      Polyline(canvas, {{x(6.2f), 0.9f}, {x(1.0f), 6.0f}, {x(6.2f), 11.1f}},
               pen);
      break;
    }
    case Glyph::kReload: {
      const cc::PaintFlags pen = Stroke(color, 1.5f);
      // Open circle running clockwise from about 1 o'clock to 12 o'clock.
      Arc(canvas, 7.0f, 10.0f, 6.2f, -50.0f, 320.0f, pen);
      Polyline(canvas, {{9.6f, 3.8f}, {6.4f, 1.0f}, {6.4f, 6.6f}},
               Fill(color), /*close=*/true);
      break;
    }
    case Glyph::kStop:
    case Glyph::kClose: {
      const float s = InkSize(glyph).width();
      const cc::PaintFlags pen = Stroke(color, glyph == Glyph::kClose ? 1.8f : 1.5f);
      Line(canvas, 0.9f, 0.9f, s - 0.9f, s - 0.9f, pen);
      Line(canvas, s - 0.9f, 0.9f, 0.9f, s - 0.9f, pen);
      break;
    }
    case Glyph::kMore: {
      const cc::PaintFlags dot = Fill(color);
      for (float cx : {2.0f, 8.0f, 14.0f}) {
        Circle(canvas, cx, 2.0f, 1.5f, dot);
      }
      break;
    }
    case Glyph::kMagnifier: {
      const cc::PaintFlags pen = Stroke(color, 1.4f);
      Circle(canvas, 5.0f, 5.0f, 4.2f, pen);
      Line(canvas, 8.1f, 8.1f, 11.3f, 11.3f, pen);
      break;
    }
    case Glyph::kLink: {
      const cc::PaintFlags pen = Stroke(color, 1.5f);
      for (const SkPoint c : {SkPoint{5.0f, 9.0f}, SkPoint{10.0f, 5.0f}}) {
        canvas->sk_canvas()->save();
        canvas->sk_canvas()->translate(c.x(), c.y());
        canvas->sk_canvas()->rotate(-45.0f);
        canvas->sk_canvas()->drawRRect(RRect(-4.4f, -2.4f, 8.8f, 4.8f, 2.4f),
                                       pen);
        canvas->sk_canvas()->restore();
      }
      break;
    }
    case Glyph::kSiteControls: {
      const cc::PaintFlags pen = Stroke(color, 1.4f);
      canvas->sk_canvas()->drawRRect(RRect(0.7f, 0.7f, 14.6f, 14.6f, 3.6f),
                                     pen);
      const cc::PaintFlags fine = Stroke(color, 1.3f);
      Line(canvas, 3.6f, 5.6f, 12.4f, 5.6f, fine);
      Line(canvas, 3.6f, 10.4f, 12.4f, 10.4f, fine);
      Circle(canvas, 10.2f, 5.6f, 1.8f, Fill(color));
      Circle(canvas, 5.8f, 10.4f, 1.8f, Fill(color));
      break;
    }
    case Glyph::kPlus:
    case Glyph::kBottomPlus: {
      const float s = InkSize(glyph).width();
      const cc::PaintFlags pen =
          Stroke(color, glyph == Glyph::kPlus ? 1.6f : 1.7f);
      Line(canvas, s / 2, 0.85f, s / 2, s - 0.85f, pen);
      Line(canvas, 0.85f, s / 2, s - 0.85f, s / 2, pen);
      break;
    }
    case Glyph::kMinus:
      Line(canvas, 1.0f, 1.0f, 13.0f, 1.0f, Stroke(color, 2.0f));
      break;
    case Glyph::kChevronDown:
      Polyline(canvas, {{0.9f, 0.9f}, {4.5f, 4.6f}, {8.1f, 0.9f}},
               Stroke(color, 1.8f));
      break;
    case Glyph::kChevronRight:
      Polyline(canvas, {{0.9f, 0.9f}, {4.6f, 4.5f}, {0.9f, 8.1f}},
               Stroke(color, 1.8f));
      break;
    case Glyph::kArrowDown: {
      const cc::PaintFlags pen = Stroke(color, 1.4f);
      Line(canvas, 4.0f, 0.8f, 4.0f, 8.2f, pen);
      Polyline(canvas, {{1.0f, 5.2f}, {4.0f, 8.2f}, {7.0f, 5.2f}}, pen);
      break;
    }
    case Glyph::kSpeaker: {
      const cc::PaintFlags pen = Stroke(color, 1.3f);
      DrawSpeakerBody(canvas, pen);
      // Three arcs (Arc's audible glyph has three).
      for (float r : {2.6f, 4.8f, 7.0f}) {
        Arc(canvas, 7.2f, 5.5f, r, -42.0f, 84.0f, pen);
      }
      break;
    }
    case Glyph::kSpeakerMuted: {
      const cc::PaintFlags pen = Stroke(color, 1.3f);
      canvas->sk_canvas()->save();
      canvas->sk_canvas()->translate(1.0f, 0.5f);
      DrawSpeakerBody(canvas, pen);
      canvas->sk_canvas()->restore();
      Line(canvas, 0.8f, 0.8f, 13.2f, 11.2f, pen);
      break;
    }
    case Glyph::kLibrary: {
      // Open's own Library mark: a filled box, a lid, two items above.
      const cc::PaintFlags fill = Fill(color);
      canvas->sk_canvas()->drawRRect(RRect(2.5f, 1.4f, 4.0f, 5.4f, 1.0f), fill);
      canvas->sk_canvas()->drawRRect(RRect(7.5f, 0.0f, 4.0f, 6.8f, 1.0f), fill);
      canvas->sk_canvas()->drawRRect(RRect(0.0f, 7.4f, 14.0f, 2.4f, 1.2f), fill);
      canvas->sk_canvas()->drawRRect(RRect(1.0f, 10.4f, 12.0f, 5.6f, 1.6f),
                                     fill);
      break;
    }
    case Glyph::kFolderClosed:
    case Glyph::kFolderOpen: {
      const cc::PaintFlags fill = Fill(color);
      if (glyph == Glyph::kFolderClosed) {
        canvas->sk_canvas()->drawRRect(RRect(0.5f, 0.8f, 7.6f, 4.6f, 1.6f),
                                       fill);
        canvas->sk_canvas()->drawRRect(RRect(0.5f, 2.8f, 17.0f, 10.8f, 2.2f),
                                       fill);
      } else {
        cc::PaintFlags back = fill;
        back.setAlphaf(SkColorGetA(color) / 255.0f * 0.55f);
        canvas->sk_canvas()->drawRRect(RRect(0.5f, 0.8f, 7.6f, 4.6f, 1.6f),
                                       back);
        canvas->sk_canvas()->drawRRect(RRect(0.5f, 2.8f, 17.0f, 10.8f, 2.2f),
                                       back);
        SkPathBuilder front;
        front.moveTo(3.2f, 6.0f);
        front.lineTo(17.6f, 6.0f);
        front.lineTo(15.4f, 13.6f);
        front.lineTo(0.6f, 13.6f);
        front.close();
        canvas->DrawPath(front.detach(), fill);
      }
      break;
    }
    case Glyph::kPlanet: {
      const cc::PaintFlags pen = Stroke(color, 1.3f);
      Circle(canvas, 7.0f, 7.0f, 4.4f, pen);
      canvas->sk_canvas()->save();
      canvas->sk_canvas()->translate(7.0f, 7.0f);
      canvas->sk_canvas()->rotate(-20.0f);
      canvas->sk_canvas()->drawOval(SkRect::MakeLTRB(-6.6f, -2.0f, 6.6f, 2.0f),
                                    pen);
      canvas->sk_canvas()->restore();
      break;
    }
    case Glyph::kWindowClose: {
      const cc::PaintFlags pen = Stroke(color, 1.1f);
      Line(canvas, 0.6f, 0.6f, 5.4f, 5.4f, pen);
      Line(canvas, 5.4f, 0.6f, 0.6f, 5.4f, pen);
      break;
    }
    case Glyph::kWindowMinimize:
      Line(canvas, 0.4f, 3.0f, 5.6f, 3.0f, Stroke(color, 1.1f));
      break;
    case Glyph::kWindowZoom: {
      const cc::PaintFlags pen = Stroke(color, 1.1f);
      Line(canvas, 3.0f, 0.4f, 3.0f, 5.6f, pen);
      Line(canvas, 0.4f, 3.0f, 5.6f, 3.0f, pen);
      break;
    }
    case Glyph::kPuzzle: {
      const cc::PaintFlags pen = Stroke(color, 1.3f);
      canvas->sk_canvas()->drawRRect(RRect(0.7f, 2.7f, 10.6f, 10.6f, 2.0f),
                                     pen);
      Circle(canvas, 6.0f, 2.4f, 1.8f, pen);
      Circle(canvas, 11.6f, 8.0f, 1.8f, pen);
      break;
    }
  }
}

void DrawLetterTile(gfx::Canvas* canvas,
                    const gfx::RectF& rect,
                    std::u16string_view label,
                    SkColor background,
                    SkColor foreground) {
  const float radius = std::max(2.0f, rect.width() * 0.22f);
  canvas->sk_canvas()->drawRRect(
      SkRRect::MakeRectXY(gfx::RectFToSkRect(rect), radius, radius),
      Fill(background));
  std::u16string letter;
  if (!label.empty()) {
    // One code point (two UTF-16 units for a surrogate pair), ASCII upper.
    const size_t n = label.size() > 1 && (label[0] & 0xFC00) == 0xD800 ? 2 : 1;
    letter = std::u16string(label.substr(0, n));
    if (n == 1 && letter[0] >= u'a' && letter[0] <= u'z') {
      letter[0] = static_cast<char16_t>(letter[0] - u'a' + u'A');
    }
  }
  if (letter.empty()) {
    return;
  }
  const gfx::FontList& font = typography::Make(
      std::max(7, static_cast<int>(std::lround(rect.height() * 0.6f))),
      gfx::Font::Weight::SEMIBOLD);
  canvas->DrawStringRectWithFlags(letter, font, foreground,
                                  gfx::ToEnclosingRect(rect),
                                  gfx::Canvas::TEXT_ALIGN_CENTER);
}

void DrawSpaceIcon(gfx::Canvas* canvas,
                   const SpaceIcon* icon,
                   std::u16string_view title,
                   const gfx::RectF& box,
                   const gfx::FontList& emoji_font,
                   SkColor tint,
                   float opacity,
                   bool grayscale) {
  cc::PaintCanvas* sk = canvas->sk_canvas();
  const bool needs_layer = grayscale || opacity < 1.0f;
  if (needs_layer) {
    cc::PaintFlags layer;
    layer.setAlphaf(std::clamp(opacity, 0.0f, 1.0f));
    if (grayscale) {
      // Rec. 709 luma matrix.
      static constexpr float kGray[20] = {
          0.2126f, 0.7152f, 0.0722f, 0, 0,  //
          0.2126f, 0.7152f, 0.0722f, 0, 0,  //
          0.2126f, 0.7152f, 0.0722f, 0, 0,  //
          0,       0,       0,       1, 0};
      layer.setColorFilter(cc::ColorFilter::MakeMatrix(kGray));
    }
    const SkRect bounds = gfx::RectFToSkRect(box);
    sk->saveLayer(bounds, layer);
  }
  if (icon && icon->kind == SpaceIconKind::kEmoji && !icon->value.empty()) {
    // Emoji sit 1 pt above center (NCC fits on F0001).
    gfx::RectF r = box;
    r.Offset(0, -1);
    canvas->DrawStringRectWithFlags(base::UTF8ToUTF16(icon->value), emoji_font,
                                    tint, gfx::ToEnclosingRect(r),
                                    gfx::Canvas::TEXT_ALIGN_CENTER);
  } else if (!icon || icon->kind == SpaceIconKind::kNamed) {
    if (!icon && !title.empty()) {
      const std::u16string letter(title.substr(0, 1));
      canvas->DrawStringRectWithFlags(
          letter, typography::Make(12, gfx::Font::Weight::SEMIBOLD), tint,
          gfx::ToEnclosingRect(box), gfx::Canvas::TEXT_ALIGN_CENTER);
    } else {
      Draw(canvas, Glyph::kPlanet, box, tint);
    }
  } else {
    // SF Symbol names are not portable: a neutral dot.
    const float r = std::min(box.width(), box.height()) * 0.18f;
    Circle(canvas, box.CenterPoint().x(), box.CenterPoint().y(), r, Fill(tint));
  }
  if (needs_layer) {
    sk->restore();
  }
}

}  // namespace open_unified::glyphs
