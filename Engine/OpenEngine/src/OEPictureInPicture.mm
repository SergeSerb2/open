// OEPictureInPicture (media-pip EM-4) over the fork's CefPictureInPictureWindow
// (cef/include/cef_media_controller.h; engine side
// open/browser/media/open_video_overlay_window.mm). While the App has set a
// delegate, video Picture in Picture opens in the App's own window: the engine
// hands over a view that shows the video and reports the player's state, and
// the App reports its window frame back. Without a delegate Chromium's own
// window is used (phase 1).
//
// Identity: CEF wraps the engine's session object anew for every callback, so
// a page's current OEPictureInPicture stands for "the session of this page".
// One Picture in Picture exists app-wide (Chromium's rule).

#import <objc/runtime.h>

#import "OEInternal.h"

#include <cmath>

static __weak id<OEPictureInPictureDelegate> gPictureInPictureDelegate;
static char kOEPictureInPictureKey;

typedef void (^OEFrameCompletion)(NSData* _Nullable);

@implementation OEPictureInPicture {
  CefRefPtr<CefPictureInPictureWindow> _window;
  CGRect _windowFrame;
  BOOL _windowVisible;
  int _captureSequence;
  NSMutableArray<OEFrameCompletion>* _frameCompletions;
}

+ (BOOL)oe_shellHostsPictureInPicture {
  return gPictureInPictureDelegate != nil;
}

- (instancetype)initOEWithWebContent:(OEWebContent*)webContent
                              window:(CefRefPtr<CefPictureInPictureWindow>)window {
  if ((self = [super init])) {
    _webContent = webContent;
    _window = window;
    _videoView = (__bridge NSView*)window->GetVideoView();
    _sourceTitle = @"";
    CefRefPtr<CefDictionaryValue> state = window->GetState();
    _kind = state && state->GetString("kind").ToString() == "document"
                ? OEPictureInPictureKindDocument
                : OEPictureInPictureKindVideo;
    [self oe_update];
  }
  return self;
}

- (BOOL)oe_isValid {
  return _window && _window->IsValid();
}

- (void)oe_invalidate {
  _window = nullptr;
  [self oe_finishFrameCaptures:nil];
}

- (void)oe_finishFrameCaptures:(nullable NSData*)png {
  NSArray<OEFrameCompletion>* pending = [_frameCompletions copy];
  [_frameCompletions removeAllObjects];
  for (OEFrameCompletion done in pending) {
    done(png);
  }
}

- (void)captureVideoFrameWithCompletion:(void (^)(NSData* _Nullable))completion {
  OEFrameCompletion done = [completion copy];
  if (!done) {
    return;
  }
  if (![self oe_isValid]) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
    return;
  }
  if (!_frameCompletions) {
    _frameCompletions = [NSMutableArray array];
  }
  // Answers exactly once, also when this object is deallocated before the
  // deadline (its pending completions are dropped unrun then).
  __block BOOL settled = NO;
  OEFrameCompletion once = ^(NSData* png) {
    if (settled) return;
    settled = YES;
    done(png);
  };
  [_frameCompletions addObject:once];
  _window->ExecuteAction("captureFrame", nullptr);
  __weak OEPictureInPicture* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   OEPictureInPicture* pip = weakSelf;
                   if (pip) [pip->_frameCompletions removeObject:once];
                   once(nil);
                 });
}

// Reads the engine's state; returns what changed.
- (OEPictureInPictureChange)oe_update {
  if (![self oe_isValid]) {
    return 0;
  }
  CefRefPtr<CefDictionaryValue> state = _window->GetState();
  if (!state) {
    return 0;
  }
  OEPictureInPictureChange changes = 0;
  // A finished frame capture (captureVideoFrameWithCompletion:).
  if (state->GetType("frameCaptureSequence") == VTYPE_INT &&
      state->GetInt("frameCaptureSequence") != _captureSequence) {
    _captureSequence = state->GetInt("frameCaptureSequence");
    NSData* png = nil;
    CefRefPtr<CefBinaryValue> binary = state->GetBinary("frameCapture");
    if (binary && binary->GetSize() > 0) {
      NSMutableData* data = [NSMutableData dataWithLength:binary->GetSize()];
      binary->GetData(data.mutableBytes, data.length, 0);
      png = data;
    }
    [self oe_finishFrameCaptures:png];
  }
  CGSize natural = CGSizeMake(state->GetInt("naturalWidth"),
                              state->GetInt("naturalHeight"));
  if (!CGSizeEqualToSize(natural, _naturalSize)) {
    _naturalSize = natural;
    changes |= OEPictureInPictureChangeNaturalSize;
  }
  _sourceBounds =
      CGRectMake(state->GetInt("sourceX"), state->GetInt("sourceY"),
                 state->GetInt("sourceWidth"), state->GetInt("sourceHeight"));
  OEPictureInPicturePlaybackState playback =
      (OEPictureInPicturePlaybackState)state->GetInt("playbackState");
  if (playback != _playbackState) {
    _playbackState = playback;
    changes |= OEPictureInPictureChangePlayback;
  }
  OEPictureInPictureControls controls =
      (OEPictureInPictureControls)state->GetInt("controls");
  if (controls != _controls) {
    _controls = controls;
    changes |= OEPictureInPictureChangeControls;
  }
  BOOL microphoneMuted = state->GetBool("microphoneMuted");
  BOOL cameraOn = state->GetBool("cameraOn");
  if (microphoneMuted != _microphoneMuted || cameraOn != _cameraOn) {
    _microphoneMuted = microphoneMuted;
    _cameraOn = cameraOn;
    changes |= OEPictureInPictureChangeMeeting;
  }
  BOOL mediaMuted = state->GetBool("mediaMuted");
  if (mediaMuted != _mediaMuted) {
    _mediaMuted = mediaMuted;
    changes |= OEPictureInPictureChangeMuted;
  }
  NSString* title = OEString(state->GetString("sourceTitle"));
  if (![title isEqualToString:_sourceTitle]) {
    _sourceTitle = [title copy];
    changes |= OEPictureInPictureChangeSourceTitle;
  }
  if (state->GetType("position") == VTYPE_DICTIONARY) {
    _position = [[OEMediaPosition alloc]
        initOEWithDictionary:state->GetDictionary("position")];
    changes |= OEPictureInPictureChangePosition;
  } else if (_position) {
    _position = nil;
    changes |= OEPictureInPictureChangePosition;
  }
  return changes;
}

- (nullable NSImage*)favicon {
  return _webContent.favicon;
}

- (CGRect)windowFrame {
  return _windowFrame;
}

- (void)setWindowFrame:(CGRect)frame {
  _windowFrame = frame;
  [self oe_reportFrame];
}

- (BOOL)isWindowVisible {
  return _windowVisible;
}

- (void)setWindowVisible:(BOOL)visible {
  _windowVisible = visible;
  [self oe_reportFrame];
}

// The engine takes screen coordinates with a top-left origin at the primary
// screen's top (Chromium's screen coordinates).
- (void)oe_reportFrame {
  if (![self oe_isValid]) {
    return;
  }
  NSScreen* primary = NSScreen.screens.firstObject;
  CGFloat top = primary ? NSMaxY(primary.frame) : 0;
  CGRect f = _windowFrame;
  CefRect rect((int)std::lround(f.origin.x),
               (int)std::lround(top - CGRectGetMaxY(f)),
               (int)std::lround(f.size.width), (int)std::lround(f.size.height));
  _window->SetWindowFrame(rect, _windowVisible);
}

- (void)oe_run:(const char*)action
           key:(const char*)key
          kind:(int)kind
         value:(double)value {
  if (![self oe_isValid]) {
    return;
  }
  CefRefPtr<CefDictionaryValue> args;
  if (key) {
    args = CefDictionaryValue::Create();
    if (kind == 0) {
      args->SetDouble(key, value);
    } else if (kind == 1) {
      args->SetBool(key, value != 0);
    } else {
      args->SetInt(key, (int)value);
    }
  }
  _window->ExecuteAction(action, args);
}

- (void)togglePlayPause { [self oe_run:"togglePlayPause" key:nullptr kind:0 value:0]; }
- (void)nextTrack { [self oe_run:"nextTrack" key:nullptr kind:0 value:0]; }
- (void)previousTrack { [self oe_run:"previousTrack" key:nullptr kind:0 value:0]; }
- (void)skipAd { [self oe_run:"skipAd" key:nullptr kind:0 value:0]; }
- (void)toggleMicrophone { [self oe_run:"toggleMicrophone" key:nullptr kind:0 value:0]; }
- (void)toggleCamera { [self oe_run:"toggleCamera" key:nullptr kind:0 value:0]; }
- (void)hangUp { [self oe_run:"hangUp" key:nullptr kind:0 value:0]; }
- (void)nextSlide { [self oe_run:"nextSlide" key:nullptr kind:0 value:0]; }
- (void)previousSlide { [self oe_run:"previousSlide" key:nullptr kind:0 value:0]; }

- (void)seekTo:(NSTimeInterval)time {
  if (std::isfinite(time)) {
    [self oe_run:"seekTo" key:"time" kind:0 value:time];
  }
}

- (void)setMuted:(BOOL)muted {
  [self oe_run:"setMuted" key:"muted" kind:1 value:muted ? 1 : 0];
}

- (void)closePausingVideo:(BOOL)pause {
  [self oe_run:"close" key:"behavior" kind:2 value:pause ? 1 : 0];
}

@end

@implementation OEEngine (PictureInPicture)

- (nullable id<OEPictureInPictureDelegate>)pictureInPictureDelegate {
  return gPictureInPictureDelegate;
}

- (void)setPictureInPictureDelegate:
    (nullable id<OEPictureInPictureDelegate>)delegate {
  gPictureInPictureDelegate = delegate;
}

- (BOOL)supportsShellPictureInPicture {
  return YES;
}

- (BOOL)supportsShellDocumentPictureInPicture {
  return YES;
}

@end

@implementation OEWebContent (OEPictureInPictureInternal)

- (nullable OEPictureInPicture*)oe_pictureInPicture {
  return objc_getAssociatedObject(self, &kOEPictureInPictureKey);
}

- (void)oe_setPictureInPicture:(nullable OEPictureInPicture*)pip {
  objc_setAssociatedObject(self, &kOEPictureInPictureKey, pip,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)oe_pictureInPictureOpened:
    (CefRefPtr<CefPictureInPictureWindow>)window {
  // A session that ended without its close arriving yet (destruction posts
  // it) goes first.
  if (OEPictureInPicture* old = [self oe_pictureInPicture]) {
    [self oe_setPictureInPicture:nil];
    [old oe_invalidate];
    [gPictureInPictureDelegate pictureInPictureDidClose:old];
  }
  OEPictureInPicture* pip =
      [[OEPictureInPicture alloc] initOEWithWebContent:self window:window];
  [self oe_setPictureInPicture:pip];
  // Synchronous: the App makes its window and sets windowFrame now, before
  // Chromium reads the window size for the renderer.
  [gPictureInPictureDelegate pictureInPictureDidOpen:pip];
}

- (void)oe_pictureInPictureChanged {
  OEPictureInPicture* pip = [self oe_pictureInPicture];
  OEPictureInPictureChange changes = [pip oe_update];
  if (pip && changes) {
    [gPictureInPictureDelegate pictureInPicture:pip didChange:changes];
  }
}

- (void)oe_pictureInPictureClosed {
  OEPictureInPicture* pip = [self oe_pictureInPicture];
  // A newer session of this page is still valid: the close was the old one's.
  if (!pip || [pip oe_isValid]) {
    return;
  }
  [self oe_setPictureInPicture:nil];
  [pip oe_invalidate];
  [gPictureInPictureDelegate pictureInPictureDidClose:pip];
}

@end
