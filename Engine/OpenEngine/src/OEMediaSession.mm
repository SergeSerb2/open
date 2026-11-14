// OEMediaSession over the fork's CefMediaController (media-pip EM-1b, EM-2,
// EM-3 = patch P6, EM-5; cef/include/cef_media_controller.h). The engine side
// is open/browser/media/open_media_controller.cc in Engine/fork/src: it
// observes Chromium's media session, players and audible state per page and
// reports a state dictionary at most once per real change.

#import "OEInternal.h"

#include <cmath>

namespace {

OEMediaActions OEMediaActionBit(NSString* name) {
  static NSDictionary<NSString*, NSNumber*>* map = @{
    @"play" : @(OEMediaActionPlay),
    @"pause" : @(OEMediaActionPause),
    @"previousTrack" : @(OEMediaActionPreviousTrack),
    @"nextTrack" : @(OEMediaActionNextTrack),
    @"seekBackward" : @(OEMediaActionSeekBackward),
    @"seekForward" : @(OEMediaActionSeekForward),
    @"seekTo" : @(OEMediaActionSeekTo),
    @"skipAd" : @(OEMediaActionSkipAd),
    @"stop" : @(OEMediaActionStop),
    @"enterPictureInPicture" : @(OEMediaActionEnterPictureInPicture),
    @"exitPictureInPicture" : @(OEMediaActionExitPictureInPicture),
    @"enterAutoPictureInPicture" : @(OEMediaActionEnterAutoPictureInPicture),
    @"toggleMicrophone" : @(OEMediaActionToggleMicrophone),
    @"toggleCamera" : @(OEMediaActionToggleCamera),
    @"hangUp" : @(OEMediaActionHangUp),
    @"previousSlide" : @(OEMediaActionPreviousSlide),
    @"nextSlide" : @(OEMediaActionNextSlide),
  };
  return (OEMediaActions)map[name].unsignedIntegerValue;
}

NSString* _Nullable OENonEmpty(CefRefPtr<CefDictionaryValue> dict,
                               const char* key) {
  NSString* text = OEString(dict->GetString(key));
  return text.length ? text : nil;
}

// Pages keep their mini player and their PiP request through this handler;
// it holds the web content weakly (the content owns the controller).
class OEMediaHandler : public CefMediaControllerHandler {
 public:
  explicit OEMediaHandler(OEWebContent* content) : content_(content) {}
  void OnAudibleChanged(CefRefPtr<CefBrowser> browser, bool audible) override {
    [content_ oe_setAudible:audible];
  }
  void OnMediaStateChanged(CefRefPtr<CefBrowser> browser) override {
    [content_ oe_mediaStateChanged];
  }
  // EM-4 (OEPictureInPicture.mm).
  bool ShouldHostPictureInPicture(CefRefPtr<CefBrowser> browser) override {
    return content_ && [OEPictureInPicture oe_shellHostsPictureInPicture];
  }
  void OnPictureInPictureOpened(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefPictureInPictureWindow> window) override {
    [content_ oe_pictureInPictureOpened:window];
  }
  void OnPictureInPictureChanged(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefPictureInPictureWindow> window) override {
    [content_ oe_pictureInPictureChanged];
  }
  void OnPictureInPictureClosed(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefPictureInPictureWindow> window) override {
    [content_ oe_pictureInPictureClosed];
  }

 private:
  __weak OEWebContent* content_;
  IMPLEMENT_REFCOUNTING(OEMediaHandler);
};

}  // namespace

#pragma mark - OEMediaPosition

@implementation OEMediaPosition

- (instancetype)initOEWithDictionary:(CefRefPtr<CefDictionaryValue>)position {
  if ((self = [super init])) {
    _duration = position->GetBool("live") ? INFINITY
                                          : position->GetDouble("duration");
    _position = position->GetDouble("position");
    _playbackRate = position->GetDouble("rate");
    _endOfMedia = position->GetBool("ended");
    _lastUpdated = [NSDate
        dateWithTimeIntervalSince1970:position->GetDouble("lastUpdated")];
  }
  return self;
}

@end

#pragma mark - Media state of one web content

typedef void (^OEPiPCompletion)(BOOL);

@interface OEMediaState : NSObject
@property(nonatomic, strong, nullable) OEMediaSession* session;
@property(nonatomic, strong) NSMutableArray<OEPiPCompletion>* pipCallbacks;
@property(nonatomic) double volume;
@end

@implementation OEMediaState {
 @public
  CefRefPtr<CefMediaController> _controller;
  CefRefPtr<OEMediaHandler> _handler;
}
- (instancetype)init {
  if ((self = [super init])) {
    _pipCallbacks = [NSMutableArray array];
    _volume = 1;
  }
  return self;
}
@end

#pragma mark - OEMediaSession

@implementation OEMediaSession

- (instancetype)initOEWithWebContent:(OEWebContent*)webContent
                               state:(CefRefPtr<CefDictionaryValue>)state {
  if ((self = [super init])) {
    _webContent = webContent;
    NSString* playback = OEString(state->GetString("playbackState"));
    _playbackState = [playback isEqualToString:@"playing"]
                         ? OEMediaPlaybackStatePlaying
                     : [playback isEqualToString:@"paused"]
                         ? OEMediaPlaybackStatePaused
                         : OEMediaPlaybackStateNone;
    _controllable = state->GetBool("controllable");
    _hasVideo = state->GetBool("hasVideo");
    _hasAudio = state->GetBool("hasAudio");
    _largestVideoSize = CGSizeMake(state->GetInt("largestVideoWidth"),
                                   state->GetInt("largestVideoHeight"));
    _pictureInPictureDisabled = state->GetBool("pictureInPictureDisabled");
    CefRefPtr<CefListValue> actions = state->GetList("actions");
    for (size_t i = 0; actions && i < actions->GetSize(); ++i) {
      _actions |= OEMediaActionBit(OEString(actions->GetString(i)));
    }
    _title = OENonEmpty(state, "title");
    _artist = OENonEmpty(state, "artist");
    _album = OENonEmpty(state, "album");
    if (state->GetType("position") == VTYPE_DICTIONARY) {
      _position = [[OEMediaPosition alloc]
          initOEWithDictionary:state->GetDictionary("position")];
    }
    _pictureInPicture = state->GetBool("pictureInPicture");
    _microphoneMuted =
        [OEString(state->GetString("microphoneState")) isEqualToString:@"muted"];
    _cameraOn = [OEString(state->GetString("cameraState")) isEqualToString:@"on"];
    _volume = state->GetDouble("volume");
  }
  return self;
}

- (void)oe_run:(const char*)action key:(const char*)key value:(double)value {
  OEMediaState* media = _webContent.oe_mediaState;
  CefRefPtr<CefMediaController> controller =
      media ? media->_controller : nullptr;
  if (!controller || !controller->IsValid()) {
    return;
  }
  CefRefPtr<CefDictionaryValue> args;
  if (key) {
    args = CefDictionaryValue::Create();
    args->SetDouble(key, value);
  }
  controller->ExecuteAction(action, args);
}

- (void)play { [self oe_run:"play" key:nullptr value:0]; }
- (void)pause { [self oe_run:"pause" key:nullptr value:0]; }
- (void)previousTrack { [self oe_run:"previousTrack" key:nullptr value:0]; }
- (void)nextTrack { [self oe_run:"nextTrack" key:nullptr value:0]; }
- (void)seekBy:(NSTimeInterval)delta { [self oe_run:"seekBy" key:"delta" value:delta]; }
- (void)seekTo:(NSTimeInterval)time { [self oe_run:"seekTo" key:"time" value:time]; }
- (void)scrubTo:(NSTimeInterval)time { [self oe_run:"scrubTo" key:"time" value:time]; }
- (void)skipAd { [self oe_run:"skipAd" key:nullptr value:0]; }
- (void)stop { [self oe_run:"stop" key:nullptr value:0]; }
- (void)toggleMicrophone { [self oe_run:"toggleMicrophone" key:nullptr value:0]; }
- (void)toggleCamera { [self oe_run:"toggleCamera" key:nullptr value:0]; }
- (void)hangUp { [self oe_run:"hangUp" key:nullptr value:0]; }

@end

#pragma mark - OEWebContent (Media)

@implementation OEWebContent (Media)

- (nullable OEMediaSession*)mediaSession {
  return self.oe_mediaState.session;
}

- (OEMediaState*)oe_media {
  if (!self.oe_mediaState) {
    self.oe_mediaState = [[OEMediaState alloc] init];
  }
  return self.oe_mediaState;
}

- (void)oe_attachMedia:(CefRefPtr<CefBrowser>)browser {
  OEMediaState* media = [self oe_media];
  if (!media->_handler) {
    media->_handler = new OEMediaHandler(self);
  }
  media->_controller =
      CefMediaController::GetForBrowser(browser, media->_handler);
  if (!media->_controller) {
    return;
  }
  if (media.volume != 1) {
    media->_controller->SetVolume(media.volume);
  }
  [self oe_setAudible:media->_controller->IsAudible()];
  if (media->_controller->GetState()->GetBool("active")) {
    [self oe_mediaStateChanged];
  }
}

- (void)oe_mediaStateChanged {
  OEMediaState* media = self.oe_mediaState;
  CefRefPtr<CefMediaController> controller =
      media ? media->_controller : nullptr;
  if (!controller || !controller->IsValid()) {
    return;
  }
  CefRefPtr<CefDictionaryValue> state = controller->GetState();
  BOOL wasPiP = media.session.pictureInPicture;
  media.session = state->GetBool("active")
                      ? [[OEMediaSession alloc] initOEWithWebContent:self
                                                               state:state]
                      : nil;
  OEWebContentChange changes = OEWebContentChangeMedia;
  if (wasPiP != media.session.pictureInPicture) {
    changes |= OEWebContentChangePictureInPicture;
  }
  if (media.session.pictureInPicture && media.pipCallbacks.count) {
    NSArray<OEPiPCompletion>* entered = [media.pipCallbacks copy];
    [media.pipCallbacks removeAllObjects];
    for (OEPiPCompletion done in entered) {
      done(YES);
    }
  }
  [self oe_notify:changes];
}

- (void)oe_resetMediaDetaching:(BOOL)detach {
  OEMediaState* media = self.oe_mediaState;
  if (!media) {
    return;
  }
  NSArray<OEPiPCompletion>* pending = [media.pipCallbacks copy];
  [media.pipCallbacks removeAllObjects];
  for (OEPiPCompletion done in pending) {
    done(NO);
  }
  if (detach) {
    media->_controller = nullptr;
  }
  if (media.session) {
    BOOL wasPiP = media.session.pictureInPicture;
    media.session = nil;
    [self oe_notify:OEWebContentChangeMedia |
                    (wasPiP ? OEWebContentChangePictureInPicture : 0)];
  }
}

- (double)mediaVolume {
  return self.oe_mediaState ? self.oe_mediaState.volume : 1;
}

- (void)setMediaVolume:(double)volume {
  volume = std::isfinite(volume) ? MIN(MAX(volume, 0.0), 1.0) : 1.0;
  OEMediaState* media = [self oe_media];
  media.volume = volume;
  if (media->_controller && media->_controller->IsValid()) {
    // The controller reports the new volume in its state (one change).
    media->_controller->SetVolume(volume);
  }
}

- (void)requestPictureInPictureWithCompletion:(void (^)(BOOL))completion {
  OEPiPCompletion done = [completion copy];
  if (!done) {
    done = ^(BOOL) {
    };
  }
  OEMediaState* media = self.oe_mediaState;
  CefRefPtr<CefMediaController> controller =
      media ? media->_controller : nullptr;
  if (media.session.pictureInPicture) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(YES); });
    return;
  }
  // The fork enters from the browser (no user activation needed) and checks
  // the video's own availability (disablePictureInPicture) first.
  if (!controller || !controller->IsValid() ||
      !controller->RequestPictureInPicture()) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(NO); });
    return;
  }
  // Answers exactly once: from the media state, or from the deadline below
  // (also when the page and its media state were deallocated meanwhile,
  // which drops pipCallbacks unrun).
  __block BOOL settled = NO;
  OEPiPCompletion once = ^(BOOL entered) {
    if (settled) return;
    settled = YES;
    done(entered);
  };
  [media.pipCallbacks addObject:once];
  // Chromium has no direct reply: a page that never enters (navigated away,
  // the request was dropped) fails after 2 s.
  __weak OEMediaState* weakMedia = media;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   [weakMedia.pipCallbacks removeObject:once];
                   once(NO);
                 });
}

- (void)exitPictureInPicturePausingVideo:(BOOL)pause {
  OEMediaState* media = self.oe_mediaState;
  if (media && media->_controller && media->_controller->IsValid()) {
    media->_controller->ExitPictureInPicture(pause ? 1 : 0);
  }
}

@end
