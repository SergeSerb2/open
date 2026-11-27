// Copyright 2026 The Open Authors. All rights reserved.
// macOS implementation of OpenPlatform.

#include "open_unified/browser/platform/open_platform.h"

#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <SystemConfiguration/SystemConfiguration.h>

#include <errno.h>
#include <math.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <map>
#include <mutex>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/apple/foundation_util.h"
#include "base/apple/scoped_cftyperef.h"
#include "base/files/file_util.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/sys_string_conversions.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/compositor/compositor.h"
#include "ui/compositor/layer.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/views/widget/widget.h"

// ===========================================================================
// Live window material: an NSVisualEffectView (behind-window blur) with the
// fitted gray wash as its only subview. Port of
// ThemeBackgroundView.updateWindowMaterial() (OpenDesign). Chromium 156's
// NativeWidgetNSWindowBridge sorts every NSVisualEffectView below its
// ViewsCompositorSuperview (IsBackgroundEffectView / SubviewSorter), so the
// material stays under the compositor on every later re-sort; the wash is a
// child of the effect view for the same reason.
// ===========================================================================

namespace {
NSString* const kOpenWindowMaterialId = @"org.openbrowser.unified.vibrancy";
NSString* const kOpenWindowControlsId = @"org.openbrowser.unified.window-controls";
// Chromium's glass-frame background views (macOS 26 GlassFrame feature).
NSString* const kChromiumOpaqueFrameBackgroundId = @"OpaqueFrameBackgroundView";

struct MacAppIconPalette {
  std::string_view id;
  SkColor stops[3];
  CGFloat positions[3];
  size_t count;
};

constexpr std::array<MacAppIconPalette, 6> kMacAppIconPalettes = {{
    {"open-indigo",
     {SkColorSetRGB(0x3B, 0x3F, 0xD8), SkColorSetRGB(0x64, 0x57, 0xF0),
      SkColorSetRGB(0xF2, 0xA3, 0x5E)},
     {0.0, 0.55, 1.0},
     3},
    {"open-obsidian",
     {SkColorSetRGB(0x17, 0x17, 0x1F), SkColorSetRGB(0x34, 0x36, 0x4A), 0},
     {0.0, 1.0, 1.0},
     2},
    {"open-sunburst",
     {SkColorSetRGB(0xF7, 0xB4, 0x55), SkColorSetRGB(0xEF, 0x5D, 0x3B), 0},
     {0.0, 1.0, 1.0},
     2},
    {"open-sage",
     {SkColorSetRGB(0x3F, 0xB6, 0x8B), SkColorSetRGB(0x14, 0x6B, 0x52), 0},
     {0.0, 1.0, 1.0},
     2},
    {"open-slate",
     {SkColorSetRGB(0x83, 0x90, 0xA6), SkColorSetRGB(0x3A, 0x44, 0x56), 0},
     {0.0, 1.0, 1.0},
     2},
    {"open-dawn",
     {SkColorSetRGB(0xF0, 0x8D, 0xB4), SkColorSetRGB(0x8C, 0x63, 0xE6), 0},
     {0.0, 1.0, 1.0},
     2},
}};

const MacAppIconPalette* FindMacAppIconPalette(std::string_view icon_id) {
  std::string_view target = icon_id.empty() ? "open-indigo" : icon_id;
  for (const MacAppIconPalette& palette : kMacAppIconPalettes) {
    if (palette.id == target) {
      return &palette;
    }
  }
  return nullptr;
}

NSImage* RenderMacAppIcon(const MacAppIconPalette& palette, CGFloat size) {
  if (size <= 0.0) {
    return nil;
  }
  const MacAppIconPalette* palette_ptr = &palette;
  return [NSImage
      imageWithSize:NSMakeSize(size, size)
            flipped:YES
     drawingHandler:^BOOL(NSRect dstRect) {
       CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
       if (!ctx) {
         return NO;
       }
       const CGFloat s = std::min(dstRect.size.width, dstRect.size.height);
       if (s <= 0.0) {
         return NO;
       }
       const CGFloat radius = s * 0.22;

       CGContextSaveGState(ctx);
       CGContextTranslateCTM(ctx, dstRect.origin.x, dstRect.origin.y);

       // Rounded squircle background with 140deg CSS linear gradient.
       base::apple::ScopedCFTypeRef<CGPathRef> rounded_rect(
           CGPathCreateWithRoundedRect(CGRectMake(0.0, 0.0, s, s), radius,
                                       radius, nullptr));
       base::apple::ScopedCFTypeRef<CGColorSpaceRef> srgb(
           CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
       if (rounded_rect && srgb) {
         CGFloat components[3 * 4] = {};
         CGFloat locations[3] = {};
         for (size_t i = 0; i < palette_ptr->count; ++i) {
           const SkColor c = palette_ptr->stops[i];
           components[i * 4 + 0] =
               static_cast<CGFloat>(SkColorGetR(c)) / 255.0;
           components[i * 4 + 1] =
               static_cast<CGFloat>(SkColorGetG(c)) / 255.0;
           components[i * 4 + 2] =
               static_cast<CGFloat>(SkColorGetB(c)) / 255.0;
           components[i * 4 + 3] = 1.0;
           locations[i] = palette_ptr->positions[i];
         }
         base::apple::ScopedCFTypeRef<CGGradientRef> gradient(
             CGGradientCreateWithColorComponents(srgb.get(), components,
                                                 locations,
                                                 palette_ptr->count));
         if (gradient) {
           constexpr CGFloat kDx = 0.6427876;
           constexpr CGFloat kDy = 0.7660444;
           const CGFloat half_len = s * 0.5 * (kDx + kDy);
           const CGPoint start = CGPointMake(s * 0.5 - kDx * half_len,
                                             s * 0.5 - kDy * half_len);
           const CGPoint end = CGPointMake(s * 0.5 + kDx * half_len,
                                           s * 0.5 + kDy * half_len);
           CGContextSaveGState(ctx);
           CGContextAddPath(ctx, rounded_rect.get());
           CGContextClip(ctx);
           CGContextDrawLinearGradient(
               ctx, gradient.get(), start, end,
               kCGGradientDrawsBeforeStartLocation |
                   kCGGradientDrawsAfterEndLocation);
           CGContextRestoreGState(ctx);
         }
       }

       // Open doorway-and-sun mark scaled from the 40x40 Settings artwork.
       const CGFloat scale = s / 40.0;
       base::apple::ScopedCFTypeRef<CGMutablePathRef> doorway(
           CGPathCreateMutable());
       if (doorway) {
         CGPathMoveToPoint(doorway.get(), nullptr, 12.0 * scale, 33.0 * scale);
         CGPathAddLineToPoint(doorway.get(), nullptr, 12.0 * scale,
                              18.5 * scale);
         CGPathAddCurveToPoint(doorway.get(), nullptr, 12.0 * scale,
                               13.8 * scale, 15.6 * scale, 10.0 * scale,
                               20.0 * scale, 10.0 * scale);
         CGPathAddCurveToPoint(doorway.get(), nullptr, 24.4 * scale,
                               10.0 * scale, 28.0 * scale, 13.8 * scale,
                               28.0 * scale, 18.5 * scale);
         CGPathAddLineToPoint(doorway.get(), nullptr, 28.0 * scale,
                              33.0 * scale);
         CGPathCloseSubpath(doorway.get());

         base::apple::ScopedCFTypeRef<CGColorRef> doorway_fill(
             CGColorCreateSRGB(1.0, 1.0, 1.0, 46.0 / 255.0));
         CGContextSetFillColorWithColor(ctx, doorway_fill.get());
         CGContextAddPath(ctx, doorway.get());
         CGContextFillPath(ctx);

         base::apple::ScopedCFTypeRef<CGColorRef> doorway_stroke(
             CGColorCreateSRGB(1.0, 1.0, 1.0, 1.0));
         CGContextSetStrokeColorWithColor(ctx, doorway_stroke.get());
         CGContextSetLineWidth(ctx, std::max<CGFloat>(1.25, 2.0 * scale));
         CGContextSetLineJoin(ctx, kCGLineJoinRound);
         CGContextSetLineCap(ctx, kCGLineCapRound);
         CGContextAddPath(ctx, doorway.get());
         CGContextStrokePath(ctx);
       }

       base::apple::ScopedCFTypeRef<CGColorRef> sun_fill(
           CGColorCreateSRGB(1.0, 0xE9 / 255.0, 0xB8 / 255.0, 1.0));
       const CGFloat sun_r = 3.6 * scale;
       CGContextSetFillColorWithColor(ctx, sun_fill.get());
       CGContextFillEllipseInRect(
           ctx, CGRectMake(20.0 * scale - sun_r, 23.0 * scale - sun_r,
                           sun_r * 2.0, sun_r * 2.0));

       CGContextRestoreGState(ctx);
       return YES;
     }];
}
}  // namespace

@interface OpenWindowMaterialView : NSVisualEffectView
@property(nonatomic, readonly) NSView* wash;
@property(nonatomic) BOOL hasSpec;
@property(nonatomic) BOOL specVibrant;
@property(nonatomic) BOOL specDarkTranslucency;
@property(nonatomic) BOOL specDarkScheme;
@property(nonatomic) BOOL specDefaultTheme;
@property(nonatomic) BOOL specActive;
@end

@implementation OpenWindowMaterialView {
  NSView* __strong _wash;
}

@synthesize wash = _wash;
@synthesize hasSpec = _hasSpec;
@synthesize specVibrant = _specVibrant;
@synthesize specDarkTranslucency = _specDarkTranslucency;
@synthesize specDarkScheme = _specDarkScheme;
@synthesize specDefaultTheme = _specDefaultTheme;
@synthesize specActive = _specActive;

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.identifier = kOpenWindowMaterialId;
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    // The material sits below the theme tint: no vibrancy on the sidebar's
    // fitted text and role colors.
    self.emphasized = NO;
    _wash = [[NSView alloc] initWithFrame:self.bounds];
    _wash.wantsLayer = YES;
    _wash.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    _wash.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_wash];
  }
  return self;
}

// The material never takes clicks: the compositor view above it does.
- (NSView*)hitTest:(NSPoint)point {
  return nil;
}

- (void)applySpec {
  if (!self.hasSpec) {
    return;
  }
  self.hidden = !self.specVibrant;
  if (!self.specVibrant) {
    return;
  }
  // Raw values 1 / 2 are the legacy light / dark materials measured in C14-T
  // (the named cases are deprecated; the semantic materials respond
  // differently to the wallpaper and to inactive windows).
  const NSVisualEffectMaterial material =
      static_cast<NSVisualEffectMaterial>(self.specDarkTranslucency ? 2 : 1);
  if (self.material != material) {
    self.material = material;
  }
  NSAppearanceName appearance_name =
      self.specDarkScheme ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
  if (![self.appearance.name isEqualToString:appearance_name]) {
    self.appearance = [NSAppearance appearanceNamed:appearance_name];
  }
  const NSVisualEffectState state = self.specActive
                                        ? NSVisualEffectStateActive
                                        : NSVisualEffectStateInactive;
  if (self.state != state) {
    self.state = state;
  }
  // Real-window C14-T output fit (window-translucency.md): a constant wash
  // over the system material; inactive windows cover the material fully.
  double opacity = 0, gray = 0, inactive_gray = 0;
  if (!self.specDefaultTheme && !self.specDarkScheme) {
    opacity = 0.4764, gray = 1, inactive_gray = 1;
  } else if (!self.specDefaultTheme && self.specDarkScheme) {
    opacity = 0.1701, gray = 0, inactive_gray = 0.8292;
  } else if (self.specDefaultTheme && !self.specDarkScheme) {
    opacity = 0.2319, gray = 0.2641, inactive_gray = 0.8366;
  } else {
    opacity = 0.1729, gray = 0, inactive_gray = 0.1023;
  }
  const double g = self.specActive ? gray : inactive_gray;
  const float o = self.specActive ? static_cast<float>(opacity) : 1.0f;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  CGColorRef color = CGColorCreateSRGB(g, g, g, 1);
  _wash.layer.backgroundColor = color;
  CGColorRelease(color);
  _wash.layer.opacity = o;
  [CATransaction commit];
}
@end

// ===========================================================================
// DimmedWindowControls: Arc's resting traffic lights. Grey circles (the
// `DimmedWindowControls` color over the background: black 0.10 on light
// content, (0.953, 0.953, 0.918) 0.33 on dark) with 1 pt colored rings while
// the window is active; under the pointer the system buttons show at full
// alpha and the circles fade out. Port of DimmedTrafficLightsView and
// BrowserWindowController.placeTrafficLights / applyTrafficLightDim. The
// view lives in the title bar view, right below the buttons, and owns the
// placement: AppKit lays the title bar out again (resize, key changes,
// pointer over the buttons) and moves the buttons back, so every button
// frame change places them again.
// ===========================================================================

@interface OpenWindowControlsView : NSView
@property(nonatomic) NSPoint groupOrigin;  // offset, window top-left points
@property(nonatomic) BOOL wantsVisible;
@property(nonatomic) BOOL wantsDimmed;
@property(nonatomic) BOOL darkContent;
@property(nonatomic) BOOL windowActive;
@property(nonatomic, readonly) BOOL pointerInside;
- (void)place;
@end

@implementation OpenWindowControlsView {
  NSTrackingArea* __strong _tracking;
  NSHashTable<NSButton*>* __strong _observedButtons;
  NSMutableArray<CAShapeLayer*>* __strong _circles;
  NSRect _groupRect;
  BOOL _placing;
  BOOL _pointerInside;
  BOOL _appliedDim;
  BOOL _hasAppliedDim;
  NSPoint _centers[3];
  NSPoint _builtCenters[3];
  BOOL _circlesDark;
  BOOL _circlesActive;
  BOOL _circlesBuilt;
}

@synthesize pointerInside = _pointerInside;
@synthesize groupOrigin = _groupOrigin;
@synthesize wantsVisible = _wantsVisible;
@synthesize wantsDimmed = _wantsDimmed;
@synthesize darkContent = _darkContent;
@synthesize windowActive = _windowActive;

// At rest the system buttons are all but transparent: still there for clicks
// and accessibility (AppKit ignores a button at alpha 0, so performClose:
// and AX presses would stop working), but 0.001 draws nothing visible.
static const CGFloat kRestButtonAlpha = 0.001;
// Motion.hoverFade.
static const NSTimeInterval kHoverFade = 0.08;

static const NSWindowButton kButtonKinds[3] = {
    NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton};

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.identifier = kOpenWindowControlsId;
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    self.wantsVisible = YES;
    self.wantsDimmed = YES;
    self.windowActive = YES;
    _observedButtons = [NSHashTable weakObjectsHashTable];
    _circles = [NSMutableArray array];
    [self setAccessibilityElement:NO];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSView*)hitTest:(NSPoint)point {
  return nil;
}

- (NSArray<NSButton*>*)buttons {
  NSMutableArray<NSButton*>* result = [NSMutableArray array];
  for (NSWindowButton kind : kButtonKinds) {
    if (NSButton* b = [self.window standardWindowButton:kind]) {
      [result addObject:b];
    }
  }
  return result;
}

- (void)observeButtons:(NSArray<NSButton*>*)buttons {
  for (NSButton* button in buttons) {
    if ([_observedButtons containsObject:button]) {
      continue;
    }
    [_observedButtons addObject:button];
    button.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(buttonFrameChanged:)
               name:NSViewFrameDidChangeNotification
             object:button];
  }
}

- (void)buttonFrameChanged:(NSNotification*)note {
  [self place];
}

- (BOOL)inFullScreen {
  return (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
}

// Window top-left point (y down) -> `view` coordinates.
- (NSPoint)pointFromTopLeft:(NSPoint)p inView:(NSView*)view {
  NSView* content = self.window.contentView;
  const NSPoint local =
      NSMakePoint(p.x, content.isFlipped ? p.y : NSHeight(content.bounds) - p.y);
  const NSPoint in_window = [content convertPoint:local toView:nil];
  return [view convertPoint:in_window fromView:nil];
}

- (void)place {
  NSWindow* window = self.window;
  if (_placing || !window) {
    return;
  }
  _placing = YES;
  NSArray<NSButton*>* buttons = [self buttons];
  [self observeButtons:buttons];
  const BOOL fullscreen = [self inFullScreen];
  if (fullscreen) {
    // AppKit shows its own buttons in the full-screen title bar.
    for (NSButton* b in buttons) {
      b.hidden = NO;
      b.alphaValue = 1;
    }
    self.hidden = YES;
    _placing = NO;
    return;
  }
  const BOOL hidden = !self.wantsVisible;
  for (NSButton* b in buttons) {
    if (b.hidden != hidden) {
      b.hidden = hidden;
    }
  }
  if (hidden) {
    self.hidden = YES;
    _pointerInside = NO;
    _placing = NO;
    return;
  }
  NSRect group = NSZeroRect;
  for (NSUInteger i = 0; i < buttons.count && i < 3; ++i) {
    NSButton* b = buttons[i];
    NSView* parent = b.superview;
    if (!parent) {
      continue;
    }
    const NSPoint target = NSMakePoint(
        open_unified::kWindowButtonCenterX[i] + self.groupOrigin.x,
        open_unified::kWindowButtonCenterY + self.groupOrigin.y);
    const NSPoint center = [self pointFromTopLeft:target inView:parent];
    const NSSize size = b.frame.size;
    const NSPoint origin = NSMakePoint(round(center.x - size.width / 2),
                                       round(center.y - size.height / 2));
    if (!NSEqualPoints(b.frame.origin, origin)) {
      [b setFrameOrigin:origin];
    }
    group = i == 0 ? b.frame : NSUnionRect(group, b.frame);
  }
  NSView* parent = buttons.count ? buttons[0].superview : nil;
  if (parent && self.superview != parent) {
    [self removeFromSuperview];
    [parent addSubview:self positioned:NSWindowBelow relativeTo:buttons[0]];
  }
  const NSRect frame = NSInsetRect(group, -2, -2);
  if (!NSEqualRects(self.frame, frame)) {
    self.frame = frame;
  }
  for (NSUInteger i = 0; i < buttons.count && i < 3; ++i) {
    _centers[i] = NSMakePoint(NSMidX(buttons[i].frame) - NSMinX(frame),
                              NSMidY(buttons[i].frame) - NSMinY(frame));
  }
  const NSRect group_rect = NSOffsetRect(group, -NSMinX(frame), -NSMinY(frame));
  if (!NSEqualRects(group_rect, _groupRect)) {
    _groupRect = group_rect;
    [self updateTrackingAreas];
  }
  self.hidden = NO;
  [self rebuildCircles];
  [self applyDimAnimated:NO];
  _placing = NO;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_tracking) {
    [self removeTrackingArea:_tracking];
    _tracking = nil;
  }
  if (NSIsEmptyRect(_groupRect)) {
    _pointerInside = NO;
    return;
  }
  _tracking = [[NSTrackingArea alloc]
      initWithRect:_groupRect
           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
             owner:self
          userInfo:nil];
  [self addTrackingArea:_tracking];
  // A rebuilt area sends no exit for a pointer that left meanwhile.
  if (self.window) {
    const NSPoint p =
        [self convertPoint:self.window.mouseLocationOutsideOfEventStream
                  fromView:nil];
    [self setPointerInside:NSPointInRect(p, _groupRect)];
  }
}

- (void)viewDidHide {
  [super viewDidHide];
  _pointerInside = NO;
}

- (void)mouseEntered:(NSEvent*)event {
  [self setPointerInside:YES];
}

- (void)mouseExited:(NSEvent*)event {
  [self setPointerInside:NO];
}

- (void)setPointerInside:(BOOL)inside {
  if (inside == _pointerInside) {
    return;
  }
  _pointerInside = inside;
  [self applyDimAnimated:YES];
}

- (void)rebuildCircles {
  if (_circlesBuilt && _circlesDark == self.darkContent &&
      _circlesActive == self.windowActive &&
      NSEqualPoints(_builtCenters[0], _centers[0]) &&
      NSEqualPoints(_builtCenters[1], _centers[1]) &&
      NSEqualPoints(_builtCenters[2], _centers[2])) {
    return;
  }
  _circlesBuilt = YES;
  for (int i = 0; i < 3; ++i) {
    _builtCenters[i] = _centers[i];
  }
  _circlesDark = self.darkContent;
  _circlesActive = self.windowActive;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (CAShapeLayer* l in _circles) {
    [l removeFromSuperlayer];
  }
  [_circles removeAllObjects];
  const BOOL dark = self.darkContent;
  // WindowControlColors.dimmed at fillOpacity (light 0.10, dark 0.33).
  const CGFloat fill_alpha = dark ? 0.33 : 0.10;
  CGColorRef fill = dark ? CGColorCreateSRGB(0.953, 0.953, 0.918, fill_alpha)
                         : CGColorCreateSRGB(0, 0, 0, fill_alpha);
  // Ring colors (closeRing / minimizeRing / zoomRing) at ringOpacity
  // (light 0.06, dark 0.34); only while the window is active.
  static const uint32_t kRingLight[3] = {0xDB3B3C, 0xD4A201, 0x2FB513};
  static const uint32_t kRingDark[3] = {0xFE8179, 0xFFDA09, 0x4DDD31};
  const CGFloat ring_alpha = dark ? 0.34 : 0.06;
  const CGFloat r = 6;  // ChromeMetrics.trafficLightDiameter / 2
  // The view is not flipped: AppKit's y grows up, circles are symmetric.
  for (int i = 0; i < 3; ++i) {
    const NSPoint c = _centers[i];
    CAShapeLayer* f = [CAShapeLayer layer];
    CGPathRef disc =
        CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), nullptr);
    f.path = disc;
    f.fillColor = fill;
    [self.layer addSublayer:f];
    [_circles addObject:f];
    if (self.windowActive) {
      const uint32_t rgb = (dark ? kRingDark : kRingLight)[i];
      CGColorRef ring_color = CGColorCreateSRGB(((rgb >> 16) & 0xFF) / 255.0,
                                                ((rgb >> 8) & 0xFF) / 255.0,
                                                (rgb & 0xFF) / 255.0, ring_alpha);
      CGMutablePathRef annulus = CGPathCreateMutable();
      CGPathAddEllipseInRect(annulus, nullptr,
                             CGRectMake(c.x - r - 1, c.y - r - 1, 2 * r + 2, 2 * r + 2));
      CGPathAddEllipseInRect(annulus, nullptr,
                             CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r));
      CAShapeLayer* ring = [CAShapeLayer layer];
      ring.path = annulus;
      ring.fillRule = kCAFillRuleEvenOdd;
      ring.fillColor = ring_color;
      [self.layer addSublayer:ring];
      [_circles addObject:ring];
      CGPathRelease(annulus);
      CGColorRelease(ring_color);
    }
    CGPathRelease(disc);
  }
  CGColorRelease(fill);
  [CATransaction commit];
}

- (void)applyDimAnimated:(BOOL)animated {
  NSArray<NSButton*>* buttons = [self buttons];
  const BOOL dim = self.wantsDimmed && !_pointerInside && ![self inFullScreen];
  const CGFloat button_alpha = dim ? kRestButtonAlpha : 1;
  const CGFloat circles_alpha = dim ? 1 : 0;
  const BOOL changed = !_hasAppliedDim || _appliedDim != dim;
  _appliedDim = dim;
  _hasAppliedDim = YES;
  if (animated && changed && self.window.isVisible && !self.hidden) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
      context.duration = kHoverFade;
      for (NSButton* b in buttons) {
        b.animator.alphaValue = button_alpha;
      }
      self.animator.alphaValue = circles_alpha;
    }];
    return;
  }
  // AppKit may reset the alpha when it lays the title bar out: put it back.
  for (NSButton* b in buttons) {
    if (b.alphaValue != button_alpha) {
      b.alphaValue = button_alpha;
    }
  }
  if (self.alphaValue != circles_alpha) {
    self.alphaValue = circles_alpha;
  }
}
@end

namespace open_unified {

namespace {

std::string HashSecretKeyHex(std::string_view service,
                             std::string_view account) {
  std::string key = std::string(service) + '\0' + std::string(account);
  uint64_t h1 = 14695981039346656037ULL;
  uint64_t h2 = 1099511628211ULL;
  for (unsigned char c : key) {
    h1 = (h1 ^ c) * 1099511628211ULL;
    h2 = (h2 * 1099511628211ULL) ^ c;
  }
  uint8_t bytes[16]{};
  for (int i = 0; i < 8; ++i) {
    bytes[i] = static_cast<uint8_t>((h1 >> (8 * i)) & 0xFFu);
    bytes[8 + i] = static_cast<uint8_t>((h2 >> (8 * i)) & 0xFFu);
  }
  return base::HexEncodeLower(bytes);
}

base::FilePath SecretFilePath(const base::FilePath& data_dir,
                              std::string_view service,
                              std::string_view account) {
  return data_dir.AppendASCII("Secrets")
      .AppendASCII(HashSecretKeyHex(service, account) + ".bin");
}

bool WriteSecretFile0600(const base::FilePath& dest,
                         const std::vector<uint8_t>& bytes) {
  base::FilePath dir = dest.DirName();
  if (!base::CreateDirectory(dir)) {
    return false;
  }
  chmod(dir.value().c_str(), 0700);
  base::FilePath tmp(dest.value() + ".tmp." +
                     base::NumberToString(static_cast<int>(getpid())));
  int fd = open(tmp.value().c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW,
                0600);
  if (fd < 0) {
    return false;
  }
  fchmod(fd, 0600);
  size_t written = 0;
  while (written < bytes.size()) {
    ssize_t n = write(fd, bytes.data() + written, bytes.size() - written);
    if (n < 0) {
      if (errno == EINTR) continue;
      close(fd);
      unlink(tmp.value().c_str());
      return false;
    }
    written += static_cast<size_t>(n);
  }
  fsync(fd);
  close(fd);
  if (rename(tmp.value().c_str(), dest.value().c_str()) != 0) {
    unlink(tmp.value().c_str());
    return false;
  }
  chmod(dest.value().c_str(), 0600);
  return true;
}

class MacFileSecretStore final : public SecretStore {
 public:
  explicit MacFileSecretStore(base::FilePath data_dir)
      : data_dir_(std::move(data_dir)) {}

  bool SaveSecret(std::string_view service,
                  std::string_view account,
                  const std::vector<uint8_t>& secret) override {
    return WriteSecretFile0600(SecretFilePath(data_dir_, service, account),
                               secret);
  }

  std::optional<std::vector<uint8_t>> LoadSecret(
      std::string_view service,
      std::string_view account) override {
    base::FilePath path = SecretFilePath(data_dir_, service, account);
    std::string raw;
    if (!base::ReadFileToStringWithMaxSize(path, &raw, 1024 * 1024)) {
      return std::nullopt;
    }
    return std::vector<uint8_t>(raw.begin(), raw.end());
  }

  bool DeleteSecret(std::string_view service,
                    std::string_view account) override {
    base::FilePath path = SecretFilePath(data_dir_, service, account);
    if (!base::PathExists(path)) {
      return true;
    }
    return base::DeleteFile(path);
  }

  bool UsesFileBackend() const override { return true; }

 private:
  base::FilePath data_dir_;
};

class MacKeychainSecretStore final : public SecretStore {
 public:
  explicit MacKeychainSecretStore(base::FilePath data_dir)
      : file_fallback_(std::move(data_dir)) {}

  bool SaveSecret(std::string_view service,
                  std::string_view account,
                  const std::vector<uint8_t>& secret) override {
    @autoreleasepool {
      NSString* ns_service = base::SysUTF8ToNSString(service);
      NSString* ns_account = base::SysUTF8ToNSString(account);
      NSData* ns_data =
          [NSData dataWithBytes:secret.data() length:secret.size()];

      NSDictionary* query = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : ns_service,
        (__bridge id)kSecAttrAccount : ns_account,
      };
      NSDictionary* update = @{
        (__bridge id)kSecValueData : ns_data,
        (__bridge id)kSecAttrAccessible :
            (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      };

      OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                      (__bridge CFDictionaryRef)update);
      if (status == errSecItemNotFound) {
        NSMutableDictionary* add_query = [query mutableCopy];
        add_query[(__bridge id)kSecValueData] = ns_data;
        add_query[(__bridge id)kSecAttrAccessible] =
            (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)add_query, nullptr);
      }
      if (status == errSecSuccess) {
        used_fallback_ = false;
        file_fallback_.DeleteSecret(service, account);
        return true;
      }
      LOG(WARNING) << "SecItem save failed (" << status
                   << "); using 0600 file fallback";
      // Remove any existing Keychain entry before writing the fallback file so
      // a stale Keychain token can never win on the next LoadSecret().
      SecItemDelete((__bridge CFDictionaryRef)query);
      used_fallback_ = true;
      return file_fallback_.SaveSecret(service, account, secret);
    }
  }

  std::optional<std::vector<uint8_t>> LoadSecret(
      std::string_view service,
      std::string_view account) override {
    @autoreleasepool {
      NSString* ns_service = base::SysUTF8ToNSString(service);
      NSString* ns_account = base::SysUTF8ToNSString(account);
      NSDictionary* query = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : ns_service,
        (__bridge id)kSecAttrAccount : ns_account,
        (__bridge id)kSecReturnData : @YES,
        (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
        (__bridge id)kSecUseAuthenticationUI :
            (__bridge id)kSecUseAuthenticationUISkip,
      };
      CFTypeRef result = nullptr;
      OSStatus status =
          SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
      if (status == errSecSuccess && result != nullptr) {
        NSData* data = (__bridge_transfer NSData*)result;
        const auto* ptr = static_cast<const uint8_t*>(data.bytes);
        return std::vector<uint8_t>(ptr, ptr + data.length);
      }
      return file_fallback_.LoadSecret(service, account);
    }
  }

  bool DeleteSecret(std::string_view service,
                    std::string_view account) override {
    @autoreleasepool {
      NSString* ns_service = base::SysUTF8ToNSString(service);
      NSString* ns_account = base::SysUTF8ToNSString(account);
      NSDictionary* query = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : ns_service,
        (__bridge id)kSecAttrAccount : ns_account,
      };
      OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
      bool kc_ok = (status == errSecSuccess || status == errSecItemNotFound);
      bool file_ok = file_fallback_.DeleteSecret(service, account);
      return kc_ok && file_ok;
    }
  }

  bool UsesFileBackend() const override { return used_fallback_; }

 private:
  MacFileSecretStore file_fallback_;
  bool used_fallback_ = false;
};

class MacCarbonHotkeyDispatcher {
 public:
  MacCarbonHotkeyDispatcher() = default;
  ~MacCarbonHotkeyDispatcher() {
    std::lock_guard<std::mutex> lock(mu_);
    for (auto& [key_id, entry] : entries_) {
      if (entry.ref) {
        UnregisterEventHotKey(entry.ref);
      }
    }
    if (handler_ref_) {
      RemoveEventHandler(handler_ref_);
      handler_ref_ = nullptr;
    }
  }

  bool Register(const GlobalHotkeySpec& spec,
                OpenPlatform::HotkeyCallback callback) {
    std::lock_guard<std::mutex> lock(mu_);
    EnsureHandlerLocked();
    UnregisterLocked(spec.id);

    UInt32 carbon_mods = 0;
    if (spec.modifiers & kHotkeyModMeta) carbon_mods |= cmdKey;
    if (spec.modifiers & kHotkeyModAlt) carbon_mods |= optionKey;
    if (spec.modifiers & kHotkeyModControl) carbon_mods |= controlKey;
    if (spec.modifiers & kHotkeyModShift) carbon_mods |= shiftKey;

    UInt32 numeric_id = next_id_++;
    EventHotKeyID hotkey_id{'OPEN', numeric_id};
    EventHotKeyRef ref = nullptr;
    OSStatus status =
        RegisterEventHotKey(spec.key_code, carbon_mods, hotkey_id,
                            GetApplicationEventTarget(), 0, &ref);
    if (status != noErr || !ref) {
      LOG(WARNING) << "RegisterEventHotKey failed (" << status << ")";
      return false;
    }
    entries_[numeric_id] = Entry{spec.id, ref, std::move(callback)};
    id_to_num_[spec.id] = numeric_id;
    return true;
  }

  bool Unregister(std::string_view id) {
    std::lock_guard<std::mutex> lock(mu_);
    return UnregisterLocked(id);
  }

 private:
  struct Entry {
    std::string id;
    EventHotKeyRef ref = nullptr;
    OpenPlatform::HotkeyCallback callback;
  };

  void EnsureHandlerLocked() {
    if (handler_ref_) {
      return;
    }
    EventTypeSpec event_spec{};
    event_spec.eventClass = kEventClassKeyboard;
    event_spec.eventKind = kEventHotKeyPressed;
    InstallApplicationEventHandler(&MacCarbonHotkeyDispatcher::OnEvent, 1,
                                   &event_spec, this, &handler_ref_);
  }

  bool UnregisterLocked(std::string_view id) {
    auto it = id_to_num_.find(std::string(id));
    if (it == id_to_num_.end()) {
      return false;
    }
    auto entry_it = entries_.find(it->second);
    if (entry_it != entries_.end()) {
      if (entry_it->second.ref) {
        UnregisterEventHotKey(entry_it->second.ref);
      }
      entries_.erase(entry_it);
    }
    id_to_num_.erase(it);
    return true;
  }

  static OSStatus OnEvent(EventHandlerCallRef /*next*/,
                          EventRef event,
                          void* user_data) {
    EventHotKeyID hotkey_id{};
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                          nullptr, sizeof(hotkey_id), nullptr,
                          &hotkey_id) != noErr) {
      return eventNotHandledErr;
    }
    auto* self = static_cast<MacCarbonHotkeyDispatcher*>(user_data);
    self->Dispatch(hotkey_id.id);
    return noErr;
  }

  void Dispatch(UInt32 numeric_id) {
    std::string id;
    OpenPlatform::HotkeyCallback cb;
    {
      std::lock_guard<std::mutex> lock(mu_);
      auto it = entries_.find(numeric_id);
      if (it == entries_.end()) {
        return;
      }
      id = it->second.id;
      cb = it->second.callback;
    }
    if (cb) {
      cb.Run(id);
    }
  }

  std::mutex mu_;
  EventHandlerRef handler_ref_ = nullptr;
  UInt32 next_id_ = 1;
  std::map<UInt32, Entry> entries_;
  std::map<std::string, UInt32> id_to_num_;
};

class OpenPlatformMac final : public OpenPlatform {
 public:
  OpenPlatformMac() = default;
  ~OpenPlatformMac() override = default;

  std::unique_ptr<SecretStore> CreateSecretStore(
      const base::FilePath& data_dir,
      bool force_file_backend) override {
    if (force_file_backend) {
      return std::make_unique<MacFileSecretStore>(data_dir);
    }
    return std::make_unique<MacKeychainSecretStore>(data_dir);
  }

  bool SetDefaultBrowser() override {
    @autoreleasepool {
      NSString* bundle_id = [[NSBundle mainBundle] bundleIdentifier];
      if (!bundle_id.length) {
        return false;
      }
      NSURL* app_url = [[NSBundle mainBundle] bundleURL];
      if (!app_url) {
        return false;
      }
      if (@available(macOS 12.0, *)) {
        void (^apply)(void) = ^{
          [[NSWorkspace sharedWorkspace]
              setDefaultApplicationAtURL:app_url
                    toOpenURLsWithScheme:@"http"
                       completionHandler:^(NSError*) {}];
          [[NSWorkspace sharedWorkspace]
              setDefaultApplicationAtURL:app_url
                    toOpenURLsWithScheme:@"https"
                       completionHandler:^(NSError*) {}];
        };
        if ([NSThread isMainThread]) {
          apply();
        } else {
          dispatch_async(dispatch_get_main_queue(), apply);
        }
        return true;
      }
      return false;
    }
  }

  bool IsDefaultBrowser() override {
    @autoreleasepool {
      NSString* self_id = [[NSBundle mainBundle] bundleIdentifier];
      if (!self_id.length) {
        return false;
      }
      NSURL* probe = [NSURL URLWithString:@"https://example.com"];
      NSURL* handler = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:probe];
      if (!handler) {
        return false;
      }
      NSBundle* handler_bundle = [NSBundle bundleWithURL:handler];
      return [handler_bundle.bundleIdentifier isEqualToString:self_id];
    }
  }

  bool RegisterGlobalHotkey(const GlobalHotkeySpec& spec,
                            HotkeyCallback callback) override {
    return hotkeys_.Register(spec, std::move(callback));
  }

  bool UnregisterGlobalHotkey(std::string_view id) override {
    return hotkeys_.Unregister(id);
  }

  void ApplyWindowEffects(views::Widget* widget, bool dark_mode) override {
    @autoreleasepool {
      NSWindow* window = WindowFor(widget);
      if (!window) {
        return;
      }
      window.appearance = [NSAppearance
          appearanceNamed:(dark_mode ? NSAppearanceNameDarkAqua
                                     : NSAppearanceNameAqua)];
      window.titlebarAppearsTransparent = YES;
      window.movableByWindowBackground = NO;
      // The material itself follows the theme (UpdateWindowEffects, driven
      // by OpenBrowserView); re-apply its last spec after the appearance
      // change, which can reset an NSVisualEffectView's subtree.
      if (OpenWindowMaterialView* material = FindMaterial(window)) {
        [material applySpec];
      }
    }
  }

  bool UpdateWindowEffects(views::Widget* widget,
                           const WindowMaterialSpec& spec) override {
    @autoreleasepool {
      NSWindow* window = WindowFor(widget);
      NSView* content_view = window.contentView;
      if (!window || !content_view) {
        return false;
      }
      OpenWindowMaterialView* material = FindMaterial(window);
      if (!spec.vibrant && !material) {
        // Opaque theme (Incognito): the theme field covers the window.
        return false;
      }
      MakeTranslucent(widget, window);
      if (!material) {
        material =
            [[OpenWindowMaterialView alloc] initWithFrame:content_view.bounds];
        // Below everything; Chromium's subview sort keeps effect views
        // under the compositor view.
        [content_view addSubview:material
                      positioned:NSWindowBelow
                      relativeTo:nil];
      }
      material.hasSpec = YES;
      material.specVibrant = spec.vibrant;
      material.specDarkTranslucency = spec.dark_translucency;
      material.specDarkScheme = spec.dark_scheme;
      material.specDefaultTheme = spec.default_theme;
      material.specActive = spec.active;
      [material applySpec];
      return spec.vibrant;
    }
  }

  void PlaceWindowButtons(views::Widget* widget,
                          const gfx::Point& origin,
                          bool visible,
                          bool dimmed) override {
    @autoreleasepool {
      OpenWindowControlsView* controls = ControlsFor(widget);
      if (!controls) {
        return;
      }
      controls.groupOrigin = NSMakePoint(origin.x(), origin.y());
      controls.wantsVisible = visible;
      controls.wantsDimmed = dimmed;
      [controls place];
    }
  }

  void SetWindowButtonsTone(views::Widget* widget,
                            bool dark_content,
                            bool active) override {
    @autoreleasepool {
      OpenWindowControlsView* controls = ControlsFor(widget);
      if (!controls || (controls.darkContent == dark_content &&
                        controls.windowActive == active)) {
        return;
      }
      controls.darkContent = dark_content;
      // At once, as macOS changes its own buttons on a key change.
      controls.windowActive = active;
      [controls place];
    }
  }

  bool IsIncreaseContrastEnabled() override {
    return [[NSWorkspace sharedWorkspace]
        accessibilityDisplayShouldIncreaseContrast];
  }

  bool SetAppIcon(const std::string& icon_id) override {
    @autoreleasepool {
      const MacAppIconPalette* palette = FindMacAppIconPalette(icon_id);
      if (!palette) {
        return false;
      }
      if (icon_id.empty() || icon_id == "open-indigo") {
        // nil restores the bundle's default icon.
        [NSApp setApplicationIconImage:nil];
        return true;
      }
      // Prefer a bundled resource if present; otherwise procedurally draw the
      // matching Open brand variant (256x256).
      NSImage* image = [NSImage imageNamed:base::SysUTF8ToNSString(icon_id)];
      if (!image) {
        image = RenderMacAppIcon(*palette, 256.0);
      }
      if (!image) {
        return false;
      }
      [NSApp setApplicationIconImage:image];
      return true;
    }
  }

  std::string ResolveExternalUrlSourceApp() override {
    @autoreleasepool {
      NSAppleEventDescriptor* event =
          [[NSAppleEventManager sharedAppleEventManager] currentAppleEvent];
      if (!event) {
        return std::string();
      }
      NSAppleEventDescriptor* pid_descriptor =
          [event attributeDescriptorForKeyword:keySenderPIDAttr];
      const pid_t pid = pid_descriptor ? pid_descriptor.int32Value : 0;
      if (pid <= 0) {
        return std::string();
      }
      NSRunningApplication* app = [NSRunningApplication
          runningApplicationWithProcessIdentifier:pid];
      NSString* bundle_id = app.bundleIdentifier;
      return bundle_id.length ? base::SysNSStringToUTF8(bundle_id)
                              : std::string();
    }
  }

  base::FilePath GetDefaultUserDataDir() override {
    @autoreleasepool {
      NSArray<NSURL*>* urls = [[NSFileManager defaultManager]
          URLsForDirectory:NSApplicationSupportDirectory
                 inDomains:NSUserDomainMask];
      if (urls.count > 0) {
        // Same directory as chrome_paths_mac.mm (hook 0008): the AppKit
        // Open keeps ~/Library/Application Support/Open until Unified
        // replaces it.
        NSURL* open_dir =
            [urls.firstObject URLByAppendingPathComponent:@"Open Unified"
                                              isDirectory:YES];
        return base::apple::NSStringToFilePath(open_dir.path);
      }
      return base::FilePath("/tmp/Open Unified");
    }
  }

  std::string GetDeviceName() override {
    // The user-visible computer name (System Settings > General > Sharing).
    // Not NSHost: +currentHost resolves host names and can block for
    // seconds (crbug.com/138570).
    base::apple::ScopedCFTypeRef<CFStringRef> name(
        SCDynamicStoreCopyComputerName(/*store=*/nullptr,
                                       /*nameEncoding=*/nullptr));
    if (name && CFStringGetLength(name.get()) > 0) {
      return base::SysCFStringRefToUTF8(name.get());
    }
    return "Mac";
  }

  std::string GetSyncPlatformName() override { return "macos"; }

 private:
  static NSWindow* WindowFor(views::Widget* widget) {
    return widget ? widget->GetNativeWindow().GetNativeNSWindow() : nil;
  }

  static OpenWindowMaterialView* FindMaterial(NSWindow* window) {
    for (NSView* subview in window.contentView.subviews) {
      if ([subview isKindOfClass:[OpenWindowMaterialView class]]) {
        return static_cast<OpenWindowMaterialView*>(subview);
      }
    }
    return nil;
  }

  static OpenWindowControlsView* ControlsFor(views::Widget* widget) {
    NSWindow* window = WindowFor(widget);
    NSButton* close = [window standardWindowButton:NSWindowCloseButton];
    NSView* parent = close.superview;
    if (!parent) {
      return nil;
    }
    for (NSView* subview in parent.subviews) {
      if ([subview isKindOfClass:[OpenWindowControlsView class]]) {
        return static_cast<OpenWindowControlsView*>(subview);
      }
    }
    OpenWindowControlsView* controls =
        [[OpenWindowControlsView alloc] initWithFrame:NSZeroRect];
    [parent addSubview:controls positioned:NSWindowBelow relativeTo:close];
    return controls;
  }

  // A non-opaque window with a transparent compositor, so the behind-window
  // material shows where the views paint translucently. Chromium's frame
  // view paint is dropped by OpenBrowserView (LAYER_NOT_DRAWN). Near-clear,
  // not clearColor: a fully clear NSWindow background makes AppKit
  // invalidate the window surface continuously (high idle CPU; see
  // NativeWidgetNSWindowBridge::InitCompositorView).
  static void MakeTranslucent(views::Widget* widget, NSWindow* window) {
    if (window.opaque) {
      window.opaque = NO;
      window.backgroundColor =
          [[NSColor windowBackgroundColor] colorWithAlphaComponent:0.001];
      [window invalidateShadow];
    }
    if (ui::Compositor* compositor = widget->GetCompositor()) {
      compositor->SetBackgroundColor(SK_ColorTRANSPARENT);
    }
    if (ui::Layer* root = widget->GetLayer()) {
      root->SetFillsBoundsOpaquely(false);
    }
    // macOS 26 glass frame (Chromium's GlassFrame feature): its opaque
    // frame-color view and glass view would cover the material.
    for (NSView* subview in window.contentView.subviews) {
      if ([subview.identifier
              isEqualToString:kChromiumOpaqueFrameBackgroundId]) {
        subview.hidden = YES;
      }
      if (@available(macOS 26, *)) {
        if ([subview isKindOfClass:[NSGlassEffectView class]]) {
          subview.hidden = YES;
        }
      }
    }
  }

  MacCarbonHotkeyDispatcher hotkeys_;
};

}  // namespace

// --- OpenPlatform base defaults (OpenPlatformMac overrides each one). -----

bool OpenPlatform::UpdateWindowEffects(views::Widget*,
                                       const WindowMaterialSpec&) {
  return false;
}

void OpenPlatform::PlaceWindowButtons(views::Widget*,
                                      const gfx::Point&,
                                      bool,
                                      bool) {}

void OpenPlatform::SetWindowButtonsTone(views::Widget*, bool, bool) {}

bool OpenPlatform::IsIncreaseContrastEnabled() {
  return false;
}

bool OpenPlatform::SetAppIcon(const std::string&) {
  return false;
}

std::string OpenPlatform::ResolveExternalUrlSourceApp() {
  return std::string();
}

// static
OpenPlatform* OpenPlatform::Get() {
  static base::NoDestructor<OpenPlatformMac> instance;
  return instance.get();
}

}  // namespace open_unified
