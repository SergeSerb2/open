// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/design/open_glyphs.h"

#include <algorithm>
#include <cmath>
#include <initializer_list>
#include <utility>

#include "base/strings/utf_string_conversions.h"
#include "build/build_config.h"
#include "cc/paint/color_filter.h"
#include "cc/paint/paint_canvas.h"
#include "cc/paint/paint_flags.h"
#include "open_unified/ui/design/open_typography.h"
#include "third_party/skia/include/core/SkBlendMode.h"
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

// Draws crisp original Skia vector paths (14 x 14 design box, scaled to fit
// `box`) for EVERY named Space icon in NamedSpaceIconSymbol on platforms
// without SF Symbols, so zero Space icons silently fall back to kPlanet.
bool DrawNamedSpaceIconVector(gfx::Canvas* canvas,
                              std::string_view raw_name,
                              std::string_view symbol_name,
                              const gfx::RectF& box,
                              SkColor color) {
  auto matches = [&](std::initializer_list<std::string_view> names) {
    for (std::string_view n : names) {
      if (raw_name == n || symbol_name == n) {
        return true;
      }
    }
    return false;
  };

  enum class SpaceVector {
    kNone,
    kBriefcase,
    kHome,
    kStar,
    kBookmark,
    kHeart,
    kFlag,
    kBolt,
    kTriangle,
    kMedical,
    kBell,
    kBulb,
    kShapes,
    kGrid,
    kApps,
    kLayers,
    kServer,
    kAlbums,
    kCopy,
    kFolder,
    kTray,
    kCalendar,
    kMail,
    kCheckbox,
    kDocument,
    kBook,
    kChat,
    kPeople,
    kTerminal,
    kHammer,
    kSquare,
    kCircle,
    kMoon,
    kSun,
    kGlobe,
    kLeaf,
    kCloudFill,
    kCloudOutline,
    kGift,
    kRestaurant,
    kBarbell,
    kAirplane,
    kMusic,
    kPalette,
    kVideo,
    kBandage,
    kCode,
    kBaseball,
    kFlame,
    kPizza,
    kSkull,
    kReceipt,
    kThumbsUp,
    kTrain,
    kLinear,
    kFigma,
    kSearch,
    kGamepad,
    kCamera,
    kRocket,
    kEyeglasses,
  };

  SpaceVector kind = SpaceVector::kNone;
  if (matches({"briefcase", "briefcase.fill"})) {
    kind = SpaceVector::kBriefcase;
  } else if (matches({"home", "house", "house.fill"})) {
    kind = SpaceVector::kHome;
  } else if (matches({"star", "star.fill"})) {
    kind = SpaceVector::kStar;
  } else if (matches({"bookmark", "bookmark.fill"})) {
    kind = SpaceVector::kBookmark;
  } else if (matches({"heart", "heart.fill"})) {
    kind = SpaceVector::kHeart;
  } else if (matches({"flag", "flag.fill"})) {
    kind = SpaceVector::kFlag;
  } else if (matches({"bolt", "bolt.fill", "flash"})) {
    kind = SpaceVector::kBolt;
  } else if (matches({"triangle", "triangle.fill"})) {
    kind = SpaceVector::kTriangle;
  } else if (matches({"medical", "cross.case", "cross.case.fill"})) {
    kind = SpaceVector::kMedical;
  } else if (matches({"notifications", "bell", "bell.fill"})) {
    kind = SpaceVector::kBell;
  } else if (matches({"bulb", "lightbulb", "lightbulb.fill"})) {
    kind = SpaceVector::kBulb;
  } else if (matches({"shapes", "square.on.circle"})) {
    kind = SpaceVector::kShapes;
  } else if (matches({"grid", "square.grid.2x2"})) {
    kind = SpaceVector::kGrid;
  } else if (matches({"apps", "square.grid.3x3"})) {
    kind = SpaceVector::kApps;
  } else if (matches({"layers", "square.3.layers.3d"})) {
    kind = SpaceVector::kLayers;
  } else if (matches({"server", "server.rack"})) {
    kind = SpaceVector::kServer;
  } else if (matches({"albums", "square.stack"})) {
    kind = SpaceVector::kAlbums;
  } else if (matches({"copy", "doc.on.doc"})) {
    kind = SpaceVector::kCopy;
  } else if (matches({"folder", "folder.fill"})) {
    kind = SpaceVector::kFolder;
  } else if (matches({"fileTrayFull", "tray.full", "tray.full.fill"})) {
    kind = SpaceVector::kTray;
  } else if (matches({"calendar"})) {
    kind = SpaceVector::kCalendar;
  } else if (matches({"mail", "envelope", "envelope.fill"})) {
    kind = SpaceVector::kMail;
  } else if (matches({"checkbox", "checkmark.square", "checkmark.square.fill"})) {
    kind = SpaceVector::kCheckbox;
  } else if (matches({"document", "doc", "doc.fill"})) {
    kind = SpaceVector::kDocument;
  } else if (matches({"book", "book.fill", "book.closed"})) {
    kind = SpaceVector::kBook;
  } else if (matches({"chatBubbleEllipses", "ellipsis.bubble"})) {
    kind = SpaceVector::kChat;
  } else if (matches({"people", "person.2", "person.2.fill"})) {
    kind = SpaceVector::kPeople;
  } else if (matches({"terminal", "terminal.fill"})) {
    kind = SpaceVector::kTerminal;
  } else if (matches({"construction", "hammer", "hammer.fill"})) {
    kind = SpaceVector::kHammer;
  } else if (matches({"square", "square.fill"})) {
    kind = SpaceVector::kSquare;
  } else if (matches({"ellipse", "circle", "circle.fill"})) {
    kind = SpaceVector::kCircle;
  } else if (matches({"moon", "moon.fill"})) {
    kind = SpaceVector::kMoon;
  } else if (matches({"sunny", "sun.max", "sun.max.fill"})) {
    kind = SpaceVector::kSun;
  } else if (matches({"planet", "globe", "globe.americas"})) {
    kind = SpaceVector::kGlobe;
  } else if (matches({"leaf", "leaf.fill"})) {
    kind = SpaceVector::kLeaf;
  } else if (matches({"cloud", "cloud.fill"})) {
    kind = SpaceVector::kCloudFill;
  } else if (matches({"cloudOutline"})) {
    kind = SpaceVector::kCloudOutline;
  } else if (matches({"gift", "gift.fill"})) {
    kind = SpaceVector::kGift;
  } else if (matches({"restaurant", "fork.knife"})) {
    kind = SpaceVector::kRestaurant;
  } else if (matches({"barbell", "dumbbell", "dumbbell.fill"})) {
    kind = SpaceVector::kBarbell;
  } else if (matches({"airplane"})) {
    kind = SpaceVector::kAirplane;
  } else if (matches({"music", "musicalNote", "music.note"})) {
    kind = SpaceVector::kMusic;
  } else if (matches({"colorPallete", "colorPalette", "paintpalette",
                      "paintpalette.fill"})) {
    kind = SpaceVector::kPalette;
  } else if (matches({"video", "video.fill"})) {
    kind = SpaceVector::kVideo;
  } else if (matches({"bandage", "bandage.fill"})) {
    kind = SpaceVector::kBandage;
  } else if (matches(
                 {"code", "github", "chevron.left.forwardslash.chevron.right"})) {
    kind = SpaceVector::kCode;
  } else if (matches({"baseball", "baseball.fill"})) {
    kind = SpaceVector::kBaseball;
  } else if (matches({"flame", "flame.fill", "bonfire"})) {
    kind = SpaceVector::kFlame;
  } else if (matches({"pizza", "fork.knife.circle"})) {
    kind = SpaceVector::kPizza;
  } else if (matches({"skull", "exclamationmark.triangle"})) {
    kind = SpaceVector::kSkull;
  } else if (matches({"receipt"})) {
    kind = SpaceVector::kReceipt;
  } else if (matches({"thumbsUp", "hand.thumbsup", "hand.thumbsup.fill"})) {
    kind = SpaceVector::kThumbsUp;
  } else if (matches({"train", "tram", "tram.fill"})) {
    kind = SpaceVector::kTrain;
  } else if (matches({"linear", "line.3.horizontal"})) {
    kind = SpaceVector::kLinear;
  } else if (matches({"figma", "square.stack.3d.up"})) {
    kind = SpaceVector::kFigma;
  } else if (matches({"search", "magnifyingglass"})) {
    kind = SpaceVector::kSearch;
  } else if (matches({"gamepad", "gamecontroller", "gamecontroller.fill"})) {
    kind = SpaceVector::kGamepad;
  } else if (matches({"camera", "camera.fill"})) {
    kind = SpaceVector::kCamera;
  } else if (matches({"rocket", "paperplane", "paperplane.fill"})) {
    kind = SpaceVector::kRocket;
  } else if (matches({"eyeglasses"})) {
    kind = SpaceVector::kEyeglasses;
  }

  if (kind == SpaceVector::kNone) {
    return false;
  }

  if (kind == SpaceVector::kEyeglasses) {
    Draw(canvas, Glyph::kEyeglasses, box, color);
    return true;
  }

  const float target =
      std::clamp(std::min(box.width(), box.height()) * 0.62f, 10.0f, 16.0f);
  const float scale = target / 14.0f;
  const float ox = box.x() + (box.width() - target) * 0.5f;
  const float oy = box.y() + (box.height() - target) * 0.5f;

  gfx::ScopedCanvas scoped(canvas);
  canvas->sk_canvas()->translate(ox, oy);
  canvas->sk_canvas()->scale(scale, scale);

  const cc::PaintFlags pen = Stroke(color, 1.35f);
  const cc::PaintFlags fine = Stroke(color, 1.15f);
  const cc::PaintFlags fill = Fill(color);

  switch (kind) {
    case SpaceVector::kBriefcase: {
      canvas->sk_canvas()->drawRRect(RRect(1.0f, 3.8f, 12.0f, 8.7f, 1.8f), pen);
      SkPathBuilder handle;
      handle.moveTo(4.7f, 3.8f);
      handle.lineTo(4.7f, 2.3f);
      handle.quadTo(4.7f, 1.4f, 5.6f, 1.4f);
      handle.lineTo(8.4f, 1.4f);
      handle.quadTo(9.3f, 1.4f, 9.3f, 2.3f);
      handle.lineTo(9.3f, 3.8f);
      canvas->DrawPath(handle.detach(), pen);
      Line(canvas, 1.2f, 7.6f, 12.8f, 7.6f, fine);
      break;
    }
    case SpaceVector::kHome: {
      Polyline(canvas, {{1.2f, 6.8f}, {7.0f, 1.6f}, {12.8f, 6.8f}}, pen);
      Polyline(canvas,
               {{2.8f, 6.0f}, {2.8f, 12.4f}, {11.2f, 12.4f}, {11.2f, 6.0f}},
               pen);
      Polyline(canvas,
               {{5.6f, 12.4f}, {5.6f, 8.4f}, {8.4f, 8.4f}, {8.4f, 12.4f}},
               fine);
      break;
    }
    case SpaceVector::kStar: {
      SkPathBuilder b;
      constexpr float kPi = 3.14159265f;
      constexpr float kOuter = 6.0f;
      constexpr float kInner = 2.6f;
      for (int i = 0; i < 10; ++i) {
        const float angle = -kPi * 0.5f + i * (kPi / 5.0f);
        const float r = (i % 2 == 0) ? kOuter : kInner;
        const float px = 7.0f + std::cos(angle) * r;
        const float py = 7.3f + std::sin(angle) * r;
        if (i == 0) {
          b.moveTo(px, py);
        } else {
          b.lineTo(px, py);
        }
      }
      b.close();
      canvas->DrawPath(b.detach(), pen);
      break;
    }
    case SpaceVector::kBookmark: {
      Polyline(canvas,
               {{3.0f, 1.4f},
                {11.0f, 1.4f},
                {11.0f, 12.6f},
                {7.0f, 9.6f},
                {3.0f, 12.6f}},
               pen, /*close=*/true);
      break;
    }
    case SpaceVector::kHeart: {
      SkPathBuilder b;
      b.moveTo(7.0f, 12.3f);
      b.cubicTo(2.4f, 9.2f, 1.1f, 6.3f, 1.4f, 4.3f);
      b.cubicTo(1.7f, 2.3f, 3.3f, 1.5f, 4.9f, 1.8f);
      b.cubicTo(5.9f, 2.0f, 6.6f, 2.7f, 7.0f, 3.6f);
      b.cubicTo(7.4f, 2.7f, 8.1f, 2.0f, 9.1f, 1.8f);
      b.cubicTo(10.7f, 1.5f, 12.3f, 2.3f, 12.6f, 4.3f);
      b.cubicTo(12.9f, 6.3f, 11.6f, 9.2f, 7.0f, 12.3f);
      b.close();
      canvas->DrawPath(b.detach(), pen);
      break;
    }
    case SpaceVector::kFlag: {
      Line(canvas, 2.6f, 1.4f, 2.6f, 12.8f, pen);
      Polyline(canvas,
               {{2.6f, 2.0f},
                {11.6f, 2.0f},
                {9.5f, 4.8f},
                {11.6f, 7.6f},
                {2.6f, 7.6f}},
               pen);
      break;
    }
    case SpaceVector::kBolt: {
      Polyline(canvas,
               {{8.1f, 1.0f},
                {2.6f, 7.6f},
                {6.7f, 7.6f},
                {5.8f, 13.0f},
                {11.4f, 6.3f},
                {7.3f, 6.3f}},
               pen, /*close=*/true);
      break;
    }
    case SpaceVector::kTriangle: {
      Polyline(canvas, {{7.0f, 1.6f}, {12.6f, 11.8f}, {1.4f, 11.8f}}, pen,
               /*close=*/true);
      break;
    }
    case SpaceVector::kMedical: {
      canvas->sk_canvas()->drawRRect(RRect(1.2f, 3.6f, 11.6f, 8.8f, 1.8f), pen);
      Polyline(canvas, {{4.8f, 3.6f}, {4.8f, 1.8f}, {9.2f, 1.8f}, {9.2f, 3.6f}},
               fine);
      Line(canvas, 7.0f, 5.7f, 7.0f, 10.3f, pen);
      Line(canvas, 4.7f, 8.0f, 9.3f, 8.0f, pen);
      break;
    }
    case SpaceVector::kBell: {
      SkPathBuilder b;
      b.moveTo(2.4f, 10.0f);
      b.lineTo(3.6f, 8.2f);
      b.lineTo(3.6f, 5.8f);
      b.cubicTo(3.6f, 1.8f, 10.4f, 1.8f, 10.4f, 5.8f);
      b.lineTo(10.4f, 8.2f);
      b.lineTo(11.6f, 10.0f);
      b.close();
      canvas->DrawPath(b.detach(), pen);
      Line(canvas, 5.5f, 12.2f, 8.5f, 12.2f, pen);
      break;
    }
    case SpaceVector::kBulb: {
      Arc(canvas, 7.0f, 5.4f, 3.9f, 132.0f, 276.0f, pen);
      Polyline(canvas, {{4.5f, 8.4f}, {5.1f, 10.4f}, {8.9f, 10.4f}, {9.5f, 8.4f}},
               pen);
      Line(canvas, 5.4f, 12.2f, 8.6f, 12.2f, fine);
      break;
    }
    case SpaceVector::kShapes: {
      canvas->sk_canvas()->drawRRect(RRect(1.4f, 1.4f, 6.8f, 6.8f, 1.2f), pen);
      Circle(canvas, 9.2f, 9.2f, 3.4f, pen);
      break;
    }
    case SpaceVector::kGrid: {
      for (int r = 0; r < 2; ++r) {
        for (int c = 0; c < 2; ++c) {
          canvas->sk_canvas()->drawRRect(
              RRect(1.4f + c * 6.2f, 1.4f + r * 6.2f, 5.0f, 5.0f, 1.2f), fine);
        }
      }
      break;
    }
    case SpaceVector::kApps: {
      for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) {
          canvas->sk_canvas()->drawRRect(
              RRect(1.3f + c * 4.1f, 1.3f + r * 4.1f, 3.0f, 3.0f, 0.8f), fine);
        }
      }
      break;
    }
    case SpaceVector::kLayers: {
      Polyline(canvas, {{7.0f, 1.5f}, {12.6f, 4.4f}, {7.0f, 7.3f}, {1.4f, 4.4f}},
               pen, /*close=*/true);
      Polyline(canvas, {{1.4f, 7.2f}, {7.0f, 10.1f}, {12.6f, 7.2f}}, fine);
      Polyline(canvas, {{1.4f, 9.8f}, {7.0f, 12.7f}, {12.6f, 9.8f}}, fine);
      break;
    }
    case SpaceVector::kServer: {
      canvas->sk_canvas()->drawRRect(RRect(1.4f, 1.8f, 11.2f, 4.4f, 1.2f), pen);
      canvas->sk_canvas()->drawRRect(RRect(1.4f, 7.8f, 11.2f, 4.4f, 1.2f), pen);
      Circle(canvas, 3.8f, 4.0f, 0.85f, fill);
      Circle(canvas, 3.8f, 10.0f, 0.85f, fill);
      Line(canvas, 6.2f, 4.0f, 10.4f, 4.0f, fine);
      Line(canvas, 6.2f, 10.0f, 10.4f, 10.0f, fine);
      break;
    }
    case SpaceVector::kAlbums: {
      canvas->sk_canvas()->drawRRect(RRect(2.0f, 4.6f, 10.0f, 7.8f, 1.5f), pen);
      Line(canvas, 3.6f, 2.8f, 10.4f, 2.8f, fine);
      Line(canvas, 4.8f, 1.3f, 9.2f, 1.3f, fine);
      break;
    }
    case SpaceVector::kCopy: {
      canvas->sk_canvas()->drawRRect(RRect(4.4f, 4.4f, 8.2f, 8.4f, 1.4f), pen);
      Polyline(canvas,
               {{2.8f, 9.6f}, {1.4f, 9.6f}, {1.4f, 1.4f}, {9.6f, 1.4f},
                {9.6f, 2.8f}},
               pen);
      break;
    }
    case SpaceVector::kFolder: {
      SkPathBuilder b;
      b.moveTo(1.2f, 3.4f);
      b.quadTo(1.2f, 2.2f, 2.4f, 2.2f);
      b.lineTo(5.4f, 2.2f);
      b.lineTo(6.8f, 3.8f);
      b.lineTo(11.6f, 3.8f);
      b.quadTo(12.8f, 3.8f, 12.8f, 5.0f);
      b.lineTo(12.8f, 10.6f);
      b.quadTo(12.8f, 11.8f, 11.6f, 11.8f);
      b.lineTo(2.4f, 11.8f);
      b.quadTo(1.2f, 11.8f, 1.2f, 10.6f);
      b.close();
      canvas->DrawPath(b.detach(), pen);
      break;
    }
    case SpaceVector::kTray: {
      Polyline(canvas,
               {{2.6f, 2.6f},
                {11.4f, 2.6f},
                {12.8f, 7.6f},
                {12.8f, 11.8f},
                {1.2f, 11.8f},
                {1.2f, 7.6f}},
               pen, /*close=*/true);
      Polyline(canvas,
               {{1.4f, 7.6f}, {4.8f, 7.6f}, {5.6f, 9.2f}, {8.4f, 9.2f},
                {9.2f, 7.6f}, {12.6f, 7.6f}},
               fine);
      Line(canvas, 4.4f, 5.1f, 9.6f, 5.1f, fine);
      break;
    }
    case SpaceVector::kCalendar: {
      canvas->sk_canvas()->drawRRect(RRect(1.4f, 2.8f, 11.2f, 9.8f, 1.6f), pen);
      Line(canvas, 1.6f, 5.8f, 12.4f, 5.8f, fine);
      Line(canvas, 4.4f, 1.2f, 4.4f, 3.8f, pen);
      Line(canvas, 9.6f, 1.2f, 9.6f, 3.8f, pen);
      break;
    }
    case SpaceVector::kMail: {
      canvas->sk_canvas()->drawRRect(RRect(1.2f, 2.8f, 11.6f, 8.4f, 1.4f), pen);
      Polyline(canvas, {{1.8f, 3.4f}, {7.0f, 7.6f}, {12.2f, 3.4f}}, fine);
      break;
    }
    case SpaceVector::kCheckbox: {
      canvas->sk_canvas()->drawRRect(RRect(1.6f, 1.6f, 10.8f, 10.8f, 2.0f), pen);
      Polyline(canvas, {{4.2f, 7.2f}, {6.2f, 9.2f}, {10.0f, 4.8f}}, pen);
      break;
    }
    case SpaceVector::kDocument: {
      Polyline(canvas,
               {{2.8f, 1.4f},
                {8.4f, 1.4f},
                {11.2f, 4.2f},
                {11.2f, 12.6f},
                {2.8f, 12.6f}},
               pen, /*close=*/true);
      Polyline(canvas, {{8.2f, 1.5f}, {8.2f, 4.4f}, {11.1f, 4.4f}}, fine);
      Line(canvas, 4.8f, 7.4f, 9.2f, 7.4f, fine);
      Line(canvas, 4.8f, 9.8f, 8.2f, 9.8f, fine);
      break;
    }
    case SpaceVector::kBook: {
      SkPathBuilder left;
      left.moveTo(7.0f, 3.2f);
      left.quadTo(4.4f, 2.0f, 1.4f, 2.6f);
      left.lineTo(1.4f, 11.4f);
      left.quadTo(4.4f, 10.8f, 7.0f, 12.0f);
      canvas->DrawPath(left.detach(), pen);
      SkPathBuilder right;
      right.moveTo(7.0f, 3.2f);
      right.quadTo(9.6f, 2.0f, 12.6f, 2.6f);
      right.lineTo(12.6f, 11.4f);
      right.quadTo(9.6f, 10.8f, 7.0f, 12.0f);
      canvas->DrawPath(right.detach(), pen);
      Line(canvas, 7.0f, 3.2f, 7.0f, 12.0f, fine);
      break;
    }
    case SpaceVector::kChat: {
      SkPathBuilder b;
      b.moveTo(7.0f, 1.8f);
      b.cubicTo(10.6f, 1.8f, 12.8f, 4.0f, 12.8f, 6.6f);
      b.cubicTo(12.8f, 9.2f, 10.6f, 11.2f, 7.0f, 11.2f);
      b.lineTo(4.8f, 11.2f);
      b.lineTo(2.0f, 12.6f);
      b.lineTo(2.8f, 10.0f);
      b.cubicTo(1.7f, 9.1f, 1.2f, 7.9f, 1.2f, 6.6f);
      b.cubicTo(1.2f, 4.0f, 3.4f, 1.8f, 7.0f, 1.8f);
      b.close();
      canvas->DrawPath(b.detach(), pen);
      for (float cx : {4.6f, 7.0f, 9.4f}) {
        Circle(canvas, cx, 6.6f, 0.85f, fill);
      }
      break;
    }
    case SpaceVector::kPeople: {
      Circle(canvas, 5.2f, 4.6f, 2.0f, pen);
      Circle(canvas, 9.6f, 5.0f, 1.6f, fine);
      SkPathBuilder b;
      b.moveTo(1.4f, 12.2f);
      b.cubicTo(1.6f, 8.6f, 8.8f, 8.6f, 9.0f, 12.2f);
      b.moveTo(9.4f, 8.6f);
      b.cubicTo(11.4f, 8.6f, 12.6f, 10.0f, 12.6f, 12.0f);
      canvas->DrawPath(b.detach(), pen);
      break;
    }
    case SpaceVector::kTerminal: {
      canvas->sk_canvas()->drawRRect(RRect(1.2f, 2.2f, 11.6f, 9.6f, 1.6f), pen);
      Polyline(canvas, {{3.4f, 5.0f}, {5.8f, 7.0f}, {3.4f, 9.0f}}, pen);
      Line(canvas, 7.0f, 9.2f, 10.4f, 9.2f, pen);
      break;
    }
    case SpaceVector::kHammer: {
      Line(canvas, 2.0f, 12.0f, 8.6f, 5.4f, Stroke(color, 1.7f));
      Polyline(canvas,
               {{6.2f, 3.0f},
                {8.4f, 1.4f},
                {12.4f, 5.4f},
                {10.6f, 7.2f},
                {8.8f, 5.4f}},
               pen, /*close=*/true);
      break;
    }
    case SpaceVector::kSquare: {
      canvas->sk_canvas()->drawRRect(RRect(1.8f, 1.8f, 10.4f, 10.4f, 1.8f), pen);
      break;
    }
    case SpaceVector::kCircle: {
      Circle(canvas, 7.0f, 7.0f, 5.4f, pen);
      break;
    }
    case SpaceVector::kMoon: {
      SkPathBuilder b;
      b.arcTo(SkRect::MakeLTRB(1.8f, 1.8f, 12.2f, 12.2f), -60.0f, 295.0f, true);
      b.quadTo(5.6f, 5.8f, 9.6f, 2.5f);
      canvas->DrawPath(b.detach(), pen);
      break;
    }
    case SpaceVector::kSun: {
      Circle(canvas, 7.0f, 7.0f, 2.6f, pen);
      constexpr float kPi = 3.14159265f;
      for (int i = 0; i < 8; ++i) {
        const float a = i * kPi * 0.25f;
        const float c = std::cos(a);
        const float s = std::sin(a);
        Line(canvas, 7.0f + c * 4.3f, 7.0f + s * 4.3f, 7.0f + c * 6.0f,
             7.0f + s * 6.0f, fine);
      }
      break;
    }
    case SpaceVector::kGlobe: {
      Circle(canvas, 7.0f, 7.0f, 5.6f, pen);
      canvas->sk_canvas()->drawOval(SkRect::MakeXYWH(4.3f, 1.4f, 5.4f, 11.2f),
                                    fine);
      Line(canvas, 1.6f, 7.0f, 12.4f, 7.0f, fine);
      break;
    }
    case SpaceVector::kLeaf: {
      SkPathBuilder leaf;
      leaf.moveTo(11.9f, 2.1f);
      leaf.cubicTo(6.2f, 1.8f, 2.4f, 5.2f, 2.6f, 11.2f);
      leaf.cubicTo(8.5f, 11.5f, 12.2f, 7.8f, 11.9f, 2.1f);
      leaf.close();
      canvas->DrawPath(leaf.detach(), pen);
      Line(canvas, 2.2f, 11.8f, 8.8f, 5.2f, fine);
      break;
    }
    case SpaceVector::kCloudFill:
    case SpaceVector::kCloudOutline: {
      SkPathBuilder b;
      b.moveTo(3.6f, 10.6f);
      b.cubicTo(0.8f, 10.6f, 0.8f, 6.2f, 3.8f, 6.2f);
      b.cubicTo(4.2f, 2.6f, 9.2f, 2.4f, 9.8f, 5.8f);
      b.cubicTo(13.0f, 5.8f, 13.0f, 10.6f, 10.2f, 10.6f);
      b.close();
      canvas->DrawPath(b.detach(),
                       kind == SpaceVector::kCloudFill ? fill : pen);
      break;
    }
    case SpaceVector::kGift: {
      canvas->sk_canvas()->drawRRect(RRect(1.8f, 5.4f, 10.4f, 7.2f, 1.2f), pen);
      Line(canvas, 1.2f, 5.4f, 12.8f, 5.4f, pen);
      Line(canvas, 7.0f, 5.4f, 7.0f, 12.6f, fine);
      Circle(canvas, 5.2f, 3.4f, 1.6f, fine);
      Circle(canvas, 8.8f, 3.4f, 1.6f, fine);
      break;
    }
    case SpaceVector::kRestaurant: {
      // Fork (left) and knife (right).
      Line(canvas, 4.4f, 1.6f, 4.4f, 12.6f, fine);
      Polyline(canvas, {{2.8f, 1.6f}, {2.8f, 5.2f}, {6.0f, 5.2f}, {6.0f, 1.6f}},
               fine);
      Line(canvas, 10.0f, 1.6f, 10.0f, 12.6f, pen);
      SkPathBuilder blade;
      blade.moveTo(10.0f, 1.6f);
      blade.cubicTo(7.8f, 2.4f, 7.8f, 6.4f, 10.0f, 7.2f);
      canvas->DrawPath(blade.detach(), fine);
      break;
    }
    case SpaceVector::kBarbell: {
      Line(canvas, 3.4f, 7.0f, 10.6f, 7.0f, pen);
      canvas->sk_canvas()->drawRRect(RRect(1.2f, 4.4f, 2.2f, 5.2f, 0.7f), pen);
      canvas->sk_canvas()->drawRRect(RRect(10.6f, 4.4f, 2.2f, 5.2f, 0.7f), pen);
      Line(canvas, 4.4f, 3.4f, 4.4f, 10.6f, pen);
      Line(canvas, 9.6f, 3.4f, 9.6f, 10.6f, pen);
      break;
    }
    case SpaceVector::kAirplane: {
      Line(canvas, 7.0f, 1.4f, 7.0f, 12.6f, pen);
      Polyline(canvas, {{1.4f, 7.4f}, {7.0f, 4.6f}, {12.6f, 7.4f}}, pen);
      Line(canvas, 4.4f, 11.4f, 9.6f, 11.4f, fine);
      break;
    }
    case SpaceVector::kMusic: {
      Line(canvas, 5.2f, 10.3f, 5.2f, 3.2f, pen);
      Line(canvas, 11.4f, 9.1f, 11.4f, 1.9f, pen);
      Line(canvas, 5.2f, 3.2f, 11.4f, 1.9f, Stroke(color, 1.7f));
      Circle(canvas, 3.7f, 10.6f, 1.8f, fill);
      Circle(canvas, 9.9f, 9.4f, 1.8f, fill);
      break;
    }
    case SpaceVector::kPalette: {
      SkPathBuilder b;
      b.arcTo(SkRect::MakeLTRB(1.4f, 1.6f, 12.6f, 12.4f), 30.0f, 300.0f, true);
      b.quadTo(9.2f, 8.6f, 9.6f, 10.4f);
      b.close();
      canvas->DrawPath(b.detach(), pen);
      Circle(canvas, 4.6f, 5.4f, 0.9f, fill);
      Circle(canvas, 7.0f, 4.0f, 0.9f, fill);
      Circle(canvas, 9.6f, 5.4f, 0.9f, fill);
      Circle(canvas, 4.8f, 8.4f, 0.9f, fill);
      break;
    }
    case SpaceVector::kVideo: {
      canvas->sk_canvas()->drawRRect(RRect(1.0f, 3.2f, 8.0f, 7.6f, 1.5f), pen);
      Polyline(canvas,
               {{9.0f, 5.4f}, {13.0f, 3.4f}, {13.0f, 10.6f}, {9.0f, 8.6f}}, pen,
               /*close=*/true);
      break;
    }
    case SpaceVector::kBandage: {
      canvas->sk_canvas()->save();
      canvas->sk_canvas()->translate(7.0f, 7.0f);
      canvas->sk_canvas()->rotate(-45.0f);
      canvas->sk_canvas()->drawRRect(RRect(-6.0f, -2.6f, 12.0f, 5.2f, 2.4f), pen);
      Line(canvas, -2.0f, -2.5f, -2.0f, 2.5f, fine);
      Line(canvas, 2.0f, -2.5f, 2.0f, 2.5f, fine);
      Circle(canvas, 0.0f, -0.8f, 0.55f, fill);
      Circle(canvas, 0.0f, 0.8f, 0.55f, fill);
      canvas->sk_canvas()->restore();
      break;
    }
    case SpaceVector::kCode: {
      Polyline(canvas, {{4.2f, 3.8f}, {1.2f, 7.0f}, {4.2f, 10.2f}}, pen);
      Polyline(canvas, {{9.8f, 3.8f}, {12.8f, 7.0f}, {9.8f, 10.2f}}, pen);
      Line(canvas, 8.2f, 2.5f, 5.8f, 11.5f, fine);
      break;
    }
    case SpaceVector::kBaseball: {
      Circle(canvas, 7.0f, 7.0f, 5.5f, pen);
      Arc(canvas, 1.5f, 7.0f, 4.2f, -45.0f, 90.0f, fine);
      Arc(canvas, 12.5f, 7.0f, 4.2f, 135.0f, 90.0f, fine);
      break;
    }
    case SpaceVector::kFlame: {
      SkPathBuilder outer;
      outer.moveTo(7.4f, 1.2f);
      outer.cubicTo(10.8f, 4.1f, 12.0f, 6.7f, 11.5f, 9.2f);
      outer.cubicTo(11.0f, 11.4f, 9.2f, 12.7f, 7.0f, 12.7f);
      outer.cubicTo(4.6f, 12.7f, 2.7f, 11.1f, 2.5f, 8.8f);
      outer.cubicTo(2.3f, 6.9f, 3.3f, 5.2f, 4.5f, 4.0f);
      outer.cubicTo(4.4f, 5.2f, 4.9f, 5.9f, 5.6f, 6.2f);
      outer.cubicTo(5.6f, 4.3f, 6.3f, 2.6f, 7.4f, 1.2f);
      outer.close();
      canvas->DrawPath(outer.detach(), pen);
      break;
    }
    case SpaceVector::kPizza: {
      SkPathBuilder slice;
      slice.moveTo(7.0f, 12.6f);
      slice.lineTo(1.8f, 3.4f);
      slice.quadTo(7.0f, 1.0f, 12.2f, 3.4f);
      slice.close();
      canvas->DrawPath(slice.detach(), pen);
      Circle(canvas, 6.0f, 5.6f, 0.9f, fill);
      Circle(canvas, 8.4f, 6.8f, 0.9f, fill);
      Circle(canvas, 7.0f, 9.0f, 0.85f, fill);
      break;
    }
    case SpaceVector::kSkull: {
      Polyline(canvas, {{7.0f, 1.5f}, {12.6f, 12.0f}, {1.4f, 12.0f}}, pen,
               /*close=*/true);
      Line(canvas, 7.0f, 5.2f, 7.0f, 8.4f, fine);
      Circle(canvas, 7.0f, 10.3f, 0.8f, fill);
      break;
    }
    case SpaceVector::kReceipt: {
      Polyline(canvas,
               {{2.8f, 1.6f},
                {11.2f, 1.6f},
                {11.2f, 12.4f},
                {9.2f, 11.0f},
                {7.0f, 12.4f},
                {4.8f, 11.0f},
                {2.8f, 12.4f}},
               pen, /*close=*/true);
      Line(canvas, 4.8f, 4.8f, 9.2f, 4.8f, fine);
      Line(canvas, 4.8f, 7.4f, 9.2f, 7.4f, fine);
      break;
    }
    case SpaceVector::kThumbsUp: {
      Polyline(canvas, {{1.8f, 6.2f}, {4.4f, 6.2f}, {4.4f, 12.2f}, {1.8f, 12.2f}},
               pen, /*close=*/true);
      SkPathBuilder hand;
      hand.moveTo(4.4f, 6.4f);
      hand.lineTo(6.8f, 2.0f);
      hand.quadTo(8.4f, 2.0f, 8.2f, 4.2f);
      hand.lineTo(7.8f, 5.8f);
      hand.lineTo(11.0f, 5.8f);
      hand.quadTo(12.4f, 5.8f, 12.2f, 7.4f);
      hand.lineTo(11.4f, 10.8f);
      hand.quadTo(11.1f, 12.2f, 9.6f, 12.2f);
      hand.lineTo(4.4f, 12.2f);
      canvas->DrawPath(hand.detach(), pen);
      break;
    }
    case SpaceVector::kTrain: {
      canvas->sk_canvas()->drawRRect(RRect(2.6f, 1.6f, 8.8f, 8.6f, 2.0f), pen);
      Line(canvas, 2.8f, 6.2f, 11.2f, 6.2f, fine);
      Circle(canvas, 4.8f, 8.2f, 0.8f, fill);
      Circle(canvas, 9.2f, 8.2f, 0.8f, fill);
      Line(canvas, 4.2f, 10.4f, 2.8f, 12.6f, fine);
      Line(canvas, 9.8f, 10.4f, 11.2f, 12.6f, fine);
      break;
    }
    case SpaceVector::kLinear: {
      Line(canvas, 1.6f, 3.4f, 12.4f, 3.4f, pen);
      Line(canvas, 1.6f, 7.0f, 12.4f, 7.0f, pen);
      Line(canvas, 1.6f, 10.6f, 12.4f, 10.6f, pen);
      break;
    }
    case SpaceVector::kFigma: {
      Polyline(canvas, {{7.0f, 1.6f}, {12.4f, 4.6f}, {7.0f, 7.6f}, {1.6f, 4.6f}},
               pen, /*close=*/true);
      Polyline(canvas, {{1.6f, 9.2f}, {7.0f, 12.2f}, {12.4f, 9.2f}}, pen);
      break;
    }
    case SpaceVector::kSearch: {
      Circle(canvas, 6.0f, 6.0f, 4.2f, pen);
      Line(canvas, 9.1f, 9.1f, 12.4f, 12.4f, pen);
      break;
    }
    case SpaceVector::kGamepad: {
      canvas->sk_canvas()->drawRRect(RRect(1.0f, 3.4f, 12.0f, 7.2f, 3.4f), pen);
      Line(canvas, 3.2f, 7.0f, 6.0f, 7.0f, fine);
      Line(canvas, 4.6f, 5.6f, 4.6f, 8.4f, fine);
      Circle(canvas, 9.2f, 7.7f, 0.9f, fill);
      Circle(canvas, 10.8f, 6.2f, 0.9f, fill);
      break;
    }
    case SpaceVector::kCamera: {
      canvas->sk_canvas()->drawRRect(RRect(1.0f, 3.6f, 12.0f, 8.6f, 1.8f), pen);
      Polyline(canvas, {{4.3f, 3.6f}, {5.2f, 1.9f}, {8.8f, 1.9f}, {9.7f, 3.6f}},
               pen);
      Circle(canvas, 7.0f, 7.9f, 2.2f, fine);
      break;
    }
    case SpaceVector::kRocket: {
      SkPathBuilder body;
      body.moveTo(12.2f, 1.8f);
      body.cubicTo(8.8f, 2.0f, 6.2f, 4.0f, 4.4f, 6.6f);
      body.lineTo(7.4f, 9.6f);
      body.cubicTo(10.0f, 7.8f, 12.0f, 5.2f, 12.2f, 1.8f);
      body.close();
      canvas->DrawPath(body.detach(), pen);
      // Side fins and exhaust.
      Polyline(canvas, {{4.8f, 6.2f}, {2.2f, 6.6f}, {3.6f, 8.6f}}, fine);
      Polyline(canvas, {{7.8f, 9.2f}, {7.4f, 11.8f}, {5.4f, 10.4f}}, fine);
      Line(canvas, 4.6f, 9.4f, 2.0f, 12.0f, fine);
      Circle(canvas, 8.8f, 5.2f, 1.0f, fill);
      break;
    }
    case SpaceVector::kEyeglasses:
    case SpaceVector::kNone:
      return false;
  }
  return true;
}

}  // namespace

std::optional<SymbolSpec> SystemSymbolFor(Glyph glyph) {
  using W = SymbolWeight;
  // Icons.swift Glyph.spec: symbol, point size, weight.
  switch (glyph) {
    case Glyph::kSidebarToggle:
      return SymbolSpec{"sidebar.left", 16, W::kMedium};
    case Glyph::kBack:
      return SymbolSpec{"arrow.left", 16, W::kRegular};
    case Glyph::kForward:
      return SymbolSpec{"arrow.right", 16, W::kRegular};
    case Glyph::kReload:
      return SymbolSpec{"arrow.clockwise", 16, W::kRegular};
    case Glyph::kStop:
      return SymbolSpec{"xmark", 13, W::kRegular};
    case Glyph::kMore:
      return SymbolSpec{"ellipsis", 13, W::kBold};
    case Glyph::kMagnifier:
      return SymbolSpec{"magnifyingglass", 12.5f, W::kRegular};
    case Glyph::kLink:
      return SymbolSpec{"link", 14, W::kMedium};
    case Glyph::kSiteControls:
      return SymbolSpec{"slider.horizontal.2.square", 18, W::kRegular};
    case Glyph::kPlus:
      return SymbolSpec{"plus", 13.5f, W::kMedium};
    case Glyph::kBottomPlus:
      return SymbolSpec{"plus", 17, W::kMedium};
    case Glyph::kClose:
      return SymbolSpec{"xmark", 13, W::kSemibold};
    case Glyph::kMinus:
      return SymbolSpec{"minus", 17, W::kSemibold};
    case Glyph::kChevronDown:
      return SymbolSpec{"chevron.down", 12, W::kBold};
    case Glyph::kChevronRight:
      return SymbolSpec{"chevron.right", 12, W::kBold};
    case Glyph::kArrowDown:
      return SymbolSpec{"arrow.down", 9, W::kSemibold};
    case Glyph::kSpeaker:
      return SymbolSpec{"speaker.wave.3", 14, W::kRegular};
    case Glyph::kSpeakerMuted:
      return SymbolSpec{"speaker.slash", 15.5f, W::kRegular};
    case Glyph::kPuzzle:
      return SymbolSpec{"puzzlepiece.extension", 16, W::kRegular};
    case Glyph::kEyeglasses:
      return SymbolSpec{"eyeglasses", 14, W::kMedium};
    case Glyph::kLockOpen:
      return SymbolSpec{"lock.open.fill", 12, W::kMedium};
    case Glyph::kInfo:
      return SymbolSpec{"info.circle", 14, W::kMedium};
    case Glyph::kWarning:
      return SymbolSpec{"exclamationmark.triangle.fill", 14, W::kMedium};
    case Glyph::kError:
      return SymbolSpec{"xmark.octagon.fill", 14, W::kMedium};
    case Glyph::kReturnArrow:
      return SymbolSpec{"arrow.uturn.backward", 12, W::kSemibold};
    // Open's own vectors (CustomIcon): no system symbol.
    case Glyph::kLibrary:
    case Glyph::kFolderClosed:
    case Glyph::kFolderOpen:
    case Glyph::kPlanet:
    case Glyph::kWindowClose:
    case Glyph::kWindowMinimize:
    case Glyph::kWindowMaximize:
    case Glyph::kWindowRestore:
    case Glyph::kWindowZoom:
    case Glyph::kOpenDoorway:
      return std::nullopt;
  }
  return std::nullopt;
}

std::string_view NamedSpaceIconSymbol(std::string_view name) {
  // NamedSpaceIcons.symbols (Open's identifier -> SF Symbol map).
  static constexpr std::pair<std::string_view, std::string_view> kMap[] = {
      {"star", "star"},
      {"bookmark", "bookmark"},
      {"heart", "heart"},
      {"flag", "flag"},
      {"flash", "bolt"},
      {"triangle", "triangle"},
      {"medical", "cross.case"},
      {"notifications", "bell"},
      {"bulb", "lightbulb"},
      {"shapes", "square.on.circle"},
      {"grid", "square.grid.2x2"},
      {"apps", "square.grid.3x3"},
      {"layers", "square.3.layers.3d"},
      {"server", "server.rack"},
      {"albums", "square.stack"},
      {"copy", "doc.on.doc"},
      {"folder", "folder"},
      {"fileTrayFull", "tray.full"},
      {"calendar", "calendar"},
      {"mail", "envelope"},
      {"checkbox", "checkmark.square"},
      {"document", "doc"},
      {"book", "book"},
      {"chatBubbleEllipses", "ellipsis.bubble"},
      {"people", "person.2"},
      {"terminal", "terminal"},
      {"construction", "hammer"},
      {"square", "square"},
      {"ellipse", "circle"},
      {"moon", "moon"},
      {"sunny", "sun.max"},
      {"planet", "globe.americas"},
      {"leaf", "leaf"},
      {"cloud", "cloud.fill"},
      {"gift", "gift"},
      {"restaurant", "fork.knife"},
      {"barbell", "dumbbell"},
      {"airplane", "airplane"},
      {"musicalNote", "music.note"},
      {"colorPallete", "paintpalette"},
      {"video", "video"},
      {"bandage", "bandage"},
      {"code", "chevron.left.forwardslash.chevron.right"},
      {"baseball", "baseball"},
      {"cloudOutline", "cloud"},
      {"bonfire", "flame"},
      {"pizza", "fork.knife.circle"},
      {"skull", "exclamationmark.triangle"},
      {"receipt", "receipt"},
      {"thumbsUp", "hand.thumbsup"},
      {"train", "tram"},
      {"github", "chevron.left.forwardslash.chevron.right"},
      {"linear", "line.3.horizontal"},
      {"figma", "square.stack.3d.up"},
      {"search", "magnifyingglass"},
      {"briefcase", "briefcase"},
      {"home", "house"},
      {"bolt", "bolt"},
      {"flame", "flame"},
      {"music", "music.note"},
      {"gamepad", "gamecontroller"},
      {"camera", "camera"},
      {"globe", "globe.americas"},
      {"rocket", "paperplane"},
  };
  for (const auto& [key, symbol] : kMap) {
    if (key == name) {
      return symbol;
    }
  }
  return "circle.dotted";
}

bool DrawNamedSpaceIcon(gfx::Canvas* canvas,
                        std::string_view name,
                        const gfx::RectF& box,
                        SkColor color) {
  return DrawNamedSpaceIconVector(canvas, name, NamedSpaceIconSymbol(name), box,
                                  color);
}

#if !BUILDFLAG(IS_MAC)
gfx::ImageSkia SystemSymbolImage(std::string_view, float, SymbolWeight) {
  return gfx::ImageSkia();
}
#endif

bool DrawSystemSymbol(gfx::Canvas* canvas,
                      std::string_view name,
                      float point_size,
                      SymbolWeight weight,
                      const gfx::RectF& bounds,
                      SkColor color,
                      gfx::Vector2dF offset) {
  const gfx::ImageSkia image = SystemSymbolImage(name, point_size, weight);
  if (image.isNull()) {
    return false;
  }
  // Pixel-aligned at the symbol's own size, centered like drawTinted.
  const float x = bounds.x() + (bounds.width() - image.width()) / 2 + offset.x();
  const float y =
      bounds.y() + (bounds.height() - image.height()) / 2 + offset.y();
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  // Template ink: keep its coverage, take the tint's color and alpha.
  flags.setColorFilter(cc::ColorFilter::MakeBlend(SkColor4f::FromColor(color),
                                                  SkBlendMode::kSrcIn));
  canvas->DrawImageInt(image, static_cast<int>(std::lround(x)),
                       static_cast<int>(std::lround(y)), flags);
  return true;
}

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
    case Glyph::kWindowMaximize:
    case Glyph::kWindowRestore:
      return {10, 10};
    case Glyph::kWindowZoom:
      return {6, 6};
    case Glyph::kPuzzle:
      return {14, 14};
    case Glyph::kEyeglasses:
      return {18, 8};
    case Glyph::kLockOpen:
      return {12, 14};
    case Glyph::kInfo:
    case Glyph::kWarning:
    case Glyph::kError:
      return {14, 14};
    case Glyph::kOpenDoorway:
      return {16, 16};
    case Glyph::kReturnArrow:
      return {12, 12};
  }
  return {12, 12};
}

void DrawWindowControlGlyph(gfx::Canvas* canvas,
                            Glyph glyph,
                            const gfx::RectF& bounds,
                            SkColor color,
                            bool linux_csd) {
  const float dsf = std::max(1.0f, canvas->image_scale());
  const float stroke_w = linux_csd ? 1.25f : (1.0f / dsf);
  auto snap = [dsf](float v) { return (std::floor(v * dsf) + 0.5f) / dsf; };

  constexpr float kInk = 10.0f;
  const float x0 = bounds.x() + (bounds.width() - kInk) * 0.5f;
  const float y0 = bounds.y() + (bounds.height() - kInk) * 0.5f;

  cc::PaintFlags pen;
  pen.setAntiAlias(true);
  pen.setStyle(cc::PaintFlags::kStroke_Style);
  pen.setStrokeWidth(stroke_w);
  pen.setStrokeCap(linux_csd ? cc::PaintFlags::kRound_Cap
                             : cc::PaintFlags::kButt_Cap);
  pen.setStrokeJoin(linux_csd ? cc::PaintFlags::kRound_Join
                              : cc::PaintFlags::kMiter_Join);
  pen.setColor(color);

  const float x_start = snap(x0);
  const float x_end = snap(x0 + kInk - stroke_w);
  const float y_start = snap(y0);
  const float y_end = snap(y0 + kInk - stroke_w);

  switch (glyph) {
    case Glyph::kWindowMinimize: {
      const float mid_y = snap(y0 + kInk * 0.5f - stroke_w * 0.5f);
      cc::PaintFlags min_pen = pen;
      if (!linux_csd) {
        min_pen.setAntiAlias(false);
        min_pen.setStrokeCap(cc::PaintFlags::kSquare_Cap);
      }
      Line(canvas, x_start, mid_y, x_end, mid_y, min_pen);
      break;
    }
    case Glyph::kWindowMaximize: {
      const float r = linux_csd ? 1.5f : 1.0f;
      const SkRect rect = SkRect::MakeLTRB(x_start, y_start, x_end, y_end);
      canvas->sk_canvas()->drawRRect(SkRRect::MakeRectXY(rect, r, r), pen);
      break;
    }
    case Glyph::kWindowRestore: {
      // Front 8x8 square at bottom-left, offset back frame at top-right.
      const float r = linux_csd ? 1.25f : 1.0f;
      const float f_left = snap(x0);
      const float f_top = snap(y0 + 2.0f);
      const float f_right = snap(x0 + 8.0f - stroke_w);
      const float f_bottom = snap(y0 + kInk - stroke_w);
      const SkRect front = SkRect::MakeLTRB(f_left, f_top, f_right, f_bottom);
      canvas->sk_canvas()->drawRRect(SkRRect::MakeRectXY(front, r, r), pen);

      const float b_left = snap(x0 + 2.0f);
      const float b_top = snap(y0);
      const float b_right = snap(x0 + kInk - stroke_w);
      const float b_bottom = snap(y0 + 8.0f - stroke_w);
      const float br = std::min(r, 1.5f);
      SkPathBuilder back;
      back.moveTo(b_left, f_top);
      back.lineTo(b_left, b_top + br);
      back.quadTo(b_left, b_top, b_left + br, b_top);
      back.lineTo(b_right - br, b_top);
      back.quadTo(b_right, b_top, b_right, b_top + br);
      back.lineTo(b_right, b_bottom - br);
      back.quadTo(b_right, b_bottom, b_right - br, b_bottom);
      back.lineTo(f_right, b_bottom);
      canvas->DrawPath(back.detach(), pen);
      break;
    }
    case Glyph::kWindowClose: {
      cc::PaintFlags close_pen = pen;
      close_pen.setAntiAlias(true);
      close_pen.setStrokeCap(cc::PaintFlags::kRound_Cap);
      const float inset = linux_csd ? 1.0f : 0.5f;
      Line(canvas, x0 + inset, y0 + inset, x0 + kInk - inset, y0 + kInk - inset,
           close_pen);
      Line(canvas, x0 + kInk - inset, y0 + inset, x0 + inset, y0 + kInk - inset,
           close_pen);
      break;
    }
    default:
      Draw(canvas, glyph, bounds, color);
      break;
  }
}

void Draw(gfx::Canvas* canvas,
          Glyph glyph,
          const gfx::RectF& bounds,
          SkColor color,
          gfx::Vector2dF offset) {
  if (glyph == Glyph::kWindowClose || glyph == Glyph::kWindowMinimize ||
      glyph == Glyph::kWindowMaximize || glyph == Glyph::kWindowRestore) {
    gfx::RectF target = bounds;
    target.Offset(offset.x(), offset.y());
#if BUILDFLAG(IS_LINUX)
    constexpr bool kDefaultLinuxCsd = true;
#else
    constexpr bool kDefaultLinuxCsd = false;
#endif
    DrawWindowControlGlyph(canvas, glyph, target, color, kDefaultLinuxCsd);
    return;
  }
#if BUILDFLAG(IS_MAC)
  if (const std::optional<SymbolSpec> spec = SystemSymbolFor(glyph)) {
    if (DrawSystemSymbol(canvas, spec->name, spec->point_size, spec->weight,
                         bounds, color, offset)) {
      return;
    }
  }
#endif
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
      // Open's default Space mark (CustomIcon.planet): a filled sphere,
      // 0.66 of the box, with a ring tilted -18 degrees.
      const float w = 14.0f, h = 14.0f;
      Circle(canvas, w / 2, h / 2, w * 0.33f, Fill(color));
      canvas->sk_canvas()->save();
      canvas->sk_canvas()->translate(w / 2, h / 2);
      canvas->sk_canvas()->rotate(-18.0f);
      canvas->sk_canvas()->drawOval(
          SkRect::MakeXYWH(-w * 0.58f, -h * 0.16f, w * 1.16f, h * 0.32f),
          Stroke(color, std::max(1.0f, w * 0.07f)));
      canvas->sk_canvas()->restore();
      break;
    }
    case Glyph::kWindowClose:
    case Glyph::kWindowMinimize:
    case Glyph::kWindowMaximize:
    case Glyph::kWindowRestore:
      // Handled above via DrawWindowControlGlyph.
      break;
    case Glyph::kWindowZoom: {
      const cc::PaintFlags pen = Stroke(color, 1.1f);
      Line(canvas, 3.0f, 0.4f, 3.0f, 5.6f, pen);
      Line(canvas, 0.4f, 3.0f, 5.6f, 3.0f, pen);
      break;
    }
    case Glyph::kEyeglasses: {
      // Two round lenses and a bridge (Open's own vector).
      const cc::PaintFlags pen = Stroke(color, 1.4f);
      Circle(canvas, 4.2f, 4.4f, 3.3f, pen);
      Circle(canvas, 13.8f, 4.4f, 3.3f, pen);
      Arc(canvas, 9.0f, 4.6f, 1.6f, 200.0f, 140.0f, pen);
      Line(canvas, 0.9f, 3.4f, 0.3f, 1.6f, pen);
      Line(canvas, 17.1f, 3.4f, 17.7f, 1.6f, pen);
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
    case Glyph::kLockOpen: {
      // Unlocked padlock (12 x 14): rounded body + open shackle raised right.
      const cc::PaintFlags pen = Stroke(color, 1.35f);
      canvas->sk_canvas()->drawRRect(RRect(1.6f, 6.4f, 8.8f, 6.6f, 1.6f), pen);
      SkPathBuilder shackle;
      shackle.moveTo(3.4f, 6.4f);
      shackle.lineTo(3.4f, 4.0f);
      shackle.arcTo(SkRect::MakeLTRB(3.4f, 1.2f, 8.8f, 6.6f), 180.0f, 150.0f,
                    false);
      canvas->DrawPath(shackle.detach(), pen);
      Circle(canvas, 6.0f, 9.7f, 0.9f, Fill(color));
      break;
    }
    case Glyph::kInfo: {
      const cc::PaintFlags pen = Stroke(color, 1.4f);
      Circle(canvas, 7.0f, 7.0f, 5.8f, pen);
      Circle(canvas, 7.0f, 4.3f, 0.85f, Fill(color));
      Line(canvas, 7.0f, 6.5f, 7.0f, 10.2f, pen);
      break;
    }
    case Glyph::kWarning: {
      const cc::PaintFlags pen = Stroke(color, 1.4f);
      Polyline(canvas, {{7.0f, 1.4f}, {12.8f, 12.2f}, {1.2f, 12.2f}}, pen,
               /*close=*/true);
      Line(canvas, 7.0f, 5.2f, 7.0f, 8.4f, pen);
      Circle(canvas, 7.0f, 10.4f, 0.85f, Fill(color));
      break;
    }
    case Glyph::kError: {
      const cc::PaintFlags pen = Stroke(color, 1.4f);
      Polyline(canvas,
               {{4.5f, 1.2f},
                {9.5f, 1.2f},
                {12.8f, 4.5f},
                {12.8f, 9.5f},
                {9.5f, 12.8f},
                {4.5f, 12.8f},
                {1.2f, 9.5f},
                {1.2f, 4.5f}},
               pen, /*close=*/true);
      Line(canvas, 4.8f, 4.8f, 9.2f, 9.2f, pen);
      Line(canvas, 9.2f, 4.8f, 4.8f, 9.2f, pen);
      break;
    }
    case Glyph::kOpenDoorway: {
      // Open's doorway-and-sun minimalist mark (16 x 16): clean arched doorway
      // with horizon threshold and rising sun disc.
      const cc::PaintFlags pen = Stroke(color, 1.45f);
      SkPathBuilder arch;
      arch.moveTo(2.4f, 14.2f);
      arch.lineTo(2.4f, 7.4f);
      arch.arcTo(SkRect::MakeLTRB(2.4f, 1.8f, 13.6f, 13.0f), 180.0f, 180.0f,
                 false);
      arch.lineTo(13.6f, 14.2f);
      canvas->DrawPath(arch.detach(), pen);
      // Threshold line at base.
      Line(canvas, 1.4f, 14.2f, 14.6f, 14.2f, pen);
      // Sun disc centered under the arch.
      Circle(canvas, 8.0f, 8.6f, 2.3f, Fill(color));
      break;
    }
    case Glyph::kReturnArrow: {
      // Curved return arrow (12 x 12) for pinned-tab reset.
      const cc::PaintFlags pen = Stroke(color, 1.45f);
      Polyline(canvas, {{4.6f, 1.8f}, {1.8f, 4.4f}, {4.6f, 7.0f}}, pen);
      SkPathBuilder tail;
      tail.moveTo(2.0f, 4.4f);
      tail.lineTo(7.4f, 4.4f);
      tail.arcTo(SkRect::MakeLTRB(4.6f, 4.4f, 10.4f, 10.2f), 270.0f, 180.0f,
                 false);
      tail.lineTo(4.6f, 10.2f);
      canvas->DrawPath(tail.detach(), pen);
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
  canvas->DrawStringRectWithFlags(
      letter, font, foreground, gfx::ToEnclosingRect(rect),
      gfx::Canvas::TEXT_ALIGN_CENTER | gfx::Canvas::NO_SUBPIXEL_RENDERING);
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
    canvas->DrawStringRectWithFlags(
        base::UTF8ToUTF16(icon->value), emoji_font, tint,
        gfx::ToEnclosingRect(r),
        gfx::Canvas::TEXT_ALIGN_CENTER | gfx::Canvas::NO_SUBPIXEL_RENDERING);
  } else if (icon && !icon->value.empty() &&
             (icon->kind == SpaceIconKind::kSymbol ||
              icon->kind == SpaceIconKind::kNamed)) {
    const std::string_view symbol = icon->kind == SpaceIconKind::kSymbol
                                        ? std::string_view(icon->value)
                                        : NamedSpaceIconSymbol(icon->value);
    // NodeIconRenderer: point size = ink height - 3, Medium, where the ink
    // is about 0.62 of the icon box (16 pt in the 26 pt header frame). An
    // unknown symbol falls back to circle.dotted, then (no system symbols)
    // to the planet mark.
    const float point_size = std::clamp(
        std::min(box.width(), box.height()) * 0.62f, 9.0f, 16.0f);
    if (!DrawSystemSymbol(canvas, symbol, point_size, SymbolWeight::kMedium,
                          box, tint) &&
        !DrawSystemSymbol(canvas, "circle.dotted", point_size,
                          SymbolWeight::kMedium, box, tint)) {
      if (!DrawNamedSpaceIconVector(canvas, icon->value, symbol, box, tint)) {
        Draw(canvas,
             symbol == "eyeglasses" ? Glyph::kEyeglasses : Glyph::kPlanet, box,
             tint);
      }
    }
  } else {
    // No icon set: Open's planet mark, never a letter.
    Draw(canvas, Glyph::kPlanet, box, tint);
  }
  if (needs_layer) {
    sk->restore();
  }
}

}  // namespace open_unified::glyphs
