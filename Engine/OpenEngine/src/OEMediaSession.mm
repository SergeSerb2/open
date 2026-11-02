// OEMediaSession over the per-frame media probe (media-pip EM-1a, EM-5
// interim). The renderer half is kMediaProbe in OEApp.mm. Every value comes
// from page-reachable state, so it drives UI only. The fork's media session
// (EM-1b) replaces the source of these values; the API stays.

#import "OEInternal.h"

namespace {

OEMediaActions OEMediaActionBit(NSString* name) {
  static NSDictionary<NSString*, NSNumber*>* map = @{
    @"play" : @(OEMediaActionPlay),
    @"pause" : @(OEMediaActionPause),
    @"previoustrack" : @(OEMediaActionPreviousTrack),
    @"nexttrack" : @(OEMediaActionNextTrack),
    @"seekbackward" : @(OEMediaActionSeekBackward),
    @"seekforward" : @(OEMediaActionSeekForward),
    @"seekto" : @(OEMediaActionSeekTo),
    @"skipad" : @(OEMediaActionSkipAd),
    @"stop" : @(OEMediaActionStop),
    @"pip" : @(OEMediaActionEnterPictureInPicture),
    @"enterpictureinpicture" : @(OEMediaActionEnterAutoPictureInPicture),
    @"togglemicrophone" : @(OEMediaActionToggleMicrophone),
    @"togglecamera" : @(OEMediaActionToggleCamera),
    @"hangup" : @(OEMediaActionHangUp),
    @"previousslide" : @(OEMediaActionPreviousSlide),
    @"nextslide" : @(OEMediaActionNextSlide),
  };
  return (OEMediaActions)map[name].unsignedIntegerValue;
}

double OENumber(id value, double fallback) {
  return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : fallback;
}

NSString* _Nullable OEText(id value) {
  return [value isKindOfClass:NSString.class] ? value : nil;
}

}  // namespace

#pragma mark - OEMediaPosition

@implementation OEMediaPosition

- (instancetype)initOEWithDuration:(NSTimeInterval)duration
                          position:(NSTimeInterval)position
                              rate:(double)rate
                             ended:(BOOL)ended {
  if ((self = [super init])) {
    _duration = duration;
    _position = position;
    _playbackRate = rate;
    _endOfMedia = ended;
    _lastUpdated = [NSDate date];
  }
  return self;
}

@end

#pragma mark - Frame store

typedef void (^OEPiPCompletion)(BOOL);

@interface OEMediaFrames : NSObject
@property(nonatomic, strong)
    NSMutableDictionary<NSString*, NSDictionary*>* states;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber*, OEPiPCompletion>* pipCallbacks;
@property(nonatomic) int nextRequest;
@property(nonatomic, strong, nullable) OEMediaSession* session;
@end

@implementation OEMediaFrames
- (instancetype)init {
  if ((self = [super init])) {
    _states = [NSMutableDictionary dictionary];
    _pipCallbacks = [NSMutableDictionary dictionary];
  }
  return self;
}
@end

#pragma mark - OEMediaSession

@implementation OEMediaSession {
  NSDictionary<NSString*, NSDictionary*>* _frames;
}

- (instancetype)initOEWithWebContent:(OEWebContent*)webContent
                              frames:(NSDictionary<NSString*, NSDictionary*>*)frames {
  if ((self = [super init])) {
    _webContent = webContent;
    _frames = [frames copy];
    BOOL playing = NO, paused = NO;
    double bestArea = -1, latest = -1;
    NSDictionary* largest = nil;
    NSDictionary* recent = nil;
    for (NSDictionary* f in frames.allValues) {
      NSString* playback = OEText(f[@"playback"]);
      playing |= [playback isEqualToString:@"playing"];
      paused |= [playback isEqualToString:@"paused"];
      _controllable |= [f[@"controllable"] boolValue];
      _hasVideo |= [f[@"video"] boolValue];
      _hasAudio |= [f[@"audio"] boolValue];
      _pictureInPicture |= [f[@"pip"] boolValue];
      for (id action in f[@"actions"]) {
        if ([action isKindOfClass:NSString.class]) {
          _actions |= OEMediaActionBit(action);
        }
      }
      if ([f[@"micMuted"] isKindOfClass:NSNumber.class]) {
        _microphoneMuted = [f[@"micMuted"] boolValue];
      }
      if ([f[@"cameraOn"] isKindOfClass:NSNumber.class]) {
        _cameraOn = [f[@"cameraOn"] boolValue];
      }
      double area = OENumber(f[@"frameArea"], 0);
      if (area > bestArea) {
        bestArea = area;
        largest = f;
      }
      double at = OENumber(f[@"lastPlayedAt"], 0);
      if (at > latest) {
        latest = at;
        recent = f;
      }
    }
    _playbackState = playing  ? OEMediaPlaybackStatePlaying
                     : paused ? OEMediaPlaybackStatePaused
                              : OEMediaPlaybackStateNone;
    if (largest) {
      _largestVideoSize = CGSizeMake(OENumber(largest[@"vw"], 0),
                                     OENumber(largest[@"vh"], 0));
      _pictureInPictureDisabled = [largest[@"pipDisabled"] boolValue];
    }
    if (_pictureInPicture) {
      _actions |= OEMediaActionExitPictureInPicture;
    }
    if (recent) {
      _title = OEText(recent[@"title"]);
      _artist = OEText(recent[@"artist"]);
      _album = OEText(recent[@"album"]);
      if ([recent[@"position"] isKindOfClass:NSNumber.class]) {
        double duration = OENumber(recent[@"duration"], 0);
        _position = [[OEMediaPosition alloc]
            initOEWithDuration:duration < 0 ? INFINITY : duration
                      position:OENumber(recent[@"position"], 0)
                          rate:OENumber(recent[@"rate"], 1)
                         ended:[recent[@"ended"] boolValue]];
      }
    }
  }
  return self;
}

/// Frames to send `command` to, most suitable first.
- (NSArray<NSString*>*)oe_framesFor:(NSString*)command {
  NSMutableArray<NSString*>* all = [NSMutableArray array];
  if ([command isEqualToString:@"pause"] || [command isEqualToString:@"stop"]) {
    [_frames enumerateKeysAndObjectsUsingBlock:^(NSString* key, NSDictionary* f, BOOL*) {
      if ([f[@"playback"] isEqual:@"playing"]) {
        [all addObject:key];
      }
    }];
    return all;
  }
  NSString* handler = command;
  if ([command isEqualToString:@"seekby"] || [command isEqualToString:@"scrubto"]) {
    handler = nil;
  }
  NSString* best = nil;
  double bestAt = -1;
  for (NSString* key in _frames) {
    NSDictionary* f = _frames[key];
    if (handler && ![@[ @"play", @"seekto" ] containsObject:handler] &&
        ![f[@"actions"] containsObject:handler]) {
      continue;
    }
    double at = OENumber(f[@"lastPlayedAt"], 0);
    if (at > bestAt) {
      bestAt = at;
      best = key;
    }
  }
  return best ? @[ best ] : @[];
}

- (void)oe_send:(NSString*)command value:(double)value {
  OEWebContent* content = _webContent;
  CefRefPtr<CefBrowser> browser = content.oe_browser;
  if (!browser) {
    return;
  }
  for (NSString* frameId in [self oe_framesFor:command]) {
    CefRefPtr<CefFrame> frame = browser->GetFrameByIdentifier(OECef(frameId));
    if (!frame) {
      continue;
    }
    CefRefPtr<CefProcessMessage> msg =
        CefProcessMessage::Create(kOEMsgMediaCommand);
    msg->GetArgumentList()->SetString(0, OECef(command));
    msg->GetArgumentList()->SetDouble(1, value);
    frame->SendProcessMessage(PID_RENDERER, msg);
  }
}

- (void)play { [self oe_send:@"play" value:0]; }
- (void)pause { [self oe_send:@"pause" value:0]; }
- (void)previousTrack { [self oe_send:@"previoustrack" value:0]; }
- (void)nextTrack { [self oe_send:@"nexttrack" value:0]; }
- (void)seekBy:(NSTimeInterval)delta { [self oe_send:@"seekby" value:delta]; }
- (void)seekTo:(NSTimeInterval)time { [self oe_send:@"seekto" value:time]; }
- (void)scrubTo:(NSTimeInterval)time { [self oe_send:@"scrubto" value:time]; }
- (void)skipAd { [self oe_send:@"skipad" value:0]; }
- (void)stop { [self oe_send:@"stop" value:0]; }
- (void)toggleMicrophone { [self oe_send:@"togglemicrophone" value:0]; }
- (void)toggleCamera { [self oe_send:@"togglecamera" value:0]; }
- (void)hangUp { [self oe_send:@"hangup" value:0]; }

@end

#pragma mark - OEWebContent (Media)

@implementation OEWebContent (Media)

- (nullable OEMediaSession*)mediaSession {
  return self.oe_mediaFrames.session;
}

- (OEMediaFrames*)oe_media {
  if (!self.oe_mediaFrames) {
    self.oe_mediaFrames = [[OEMediaFrames alloc] init];
  }
  return self.oe_mediaFrames;
}

- (void)oe_mediaReport:(NSString*)kind json:(NSString*)json frame:(NSString*)frameId {
  OEMediaFrames* media = [self oe_media];
  NSData* data = [json dataUsingEncoding:NSUTF8StringEncoding];
  id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  NSDictionary* dict = [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
  if ([kind isEqualToString:@"pip"]) {
    NSNumber* request = [dict[@"id"] isKindOfClass:NSNumber.class] ? dict[@"id"] : nil;
    OEPiPCompletion done = nil;
    if (request) {
      done = media.pipCallbacks[@(request.intValue)];
    }
    if (done) {
      [media.pipCallbacks removeObjectForKey:@(request.intValue)];
      done([dict[@"ok"] boolValue]);
    }
    return;
  }
  if (dict.count) {
    media.states[frameId] = dict;
  } else if (media.states[frameId]) {
    [media.states removeObjectForKey:frameId];
  } else {
    return;
  }
  [self oe_rebuildMedia];
}

- (void)oe_rebuildMedia {
  OEMediaFrames* media = [self oe_media];
  BOOL wasPiP = media.session.pictureInPicture;
  media.session = media.states.count
                      ? [[OEMediaSession alloc] initOEWithWebContent:self
                                                              frames:media.states]
                      : nil;
  OEWebContentChange changes = OEWebContentChangeMedia;
  if (wasPiP != media.session.pictureInPicture) {
    changes |= OEWebContentChangePictureInPicture;
  }
  [self oe_notify:changes];
}

- (void)oe_resetMedia {
  OEMediaFrames* media = self.oe_mediaFrames;
  if (!media) {
    return;
  }
  NSArray<OEPiPCompletion>* pending = media.pipCallbacks.allValues;
  [media.pipCallbacks removeAllObjects];
  for (OEPiPCompletion done in pending) {
    done(NO);
  }
  if (media.states.count) {
    [media.states removeAllObjects];
    [self oe_rebuildMedia];
  }
}

- (void)requestPictureInPictureWithCompletion:(void (^)(BOOL))completion {
  OEPiPCompletion done = [completion copy];
  if (!done) {
    done = ^(BOOL) {
    };
  }
  OEMediaSession* session = self.mediaSession;
  if (!self.oe_browser || !session ||
      !(session.actions & OEMediaActionEnterPictureInPicture)) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(NO); });
    return;
  }
  OEMediaFrames* media = [self oe_media];
  int request = ++media.nextRequest;
  media.pipCallbacks[@(request)] = done;
  __weak OEWebContent* weakSelf = self;
  // requestPictureInPicture() needs transient user activation. The DevTools
  // evaluation carries a user gesture to the main frame (EM-5 interim; the
  // fork path skips the activation check instead).
  [self evaluateJavaScript:@"1"
                completion:^(id, NSError*) {
                  OEWebContent* content = weakSelf;
                  OEMediaSession* now = content.mediaSession;
                  if (!content || !now) {
                    return;
                  }
                  NSString* frameId = nil;
                  double bestArea = -1;
                  for (NSString* key in content.oe_mediaFrames.states) {
                    NSDictionary* f = content.oe_mediaFrames.states[key];
                    if (![f[@"actions"] containsObject:@"pip"]) {
                      continue;
                    }
                    double area = OENumber(f[@"frameArea"], 0);
                    if (area > bestArea) {
                      bestArea = area;
                      frameId = key;
                    }
                  }
                  CefRefPtr<CefFrame> frame =
                      frameId && content.oe_browser
                          ? content.oe_browser->GetFrameByIdentifier(OECef(frameId))
                          : nullptr;
                  if (!frame) {
                    OEPiPCompletion pending = content.oe_mediaFrames.pipCallbacks[@(request)];
                    [content.oe_mediaFrames.pipCallbacks removeObjectForKey:@(request)];
                    if (pending) {
                      pending(NO);
                    }
                    return;
                  }
                  CefRefPtr<CefProcessMessage> msg =
                      CefProcessMessage::Create(kOEMsgMediaCommand);
                  msg->GetArgumentList()->SetString(0, "pip");
                  msg->GetArgumentList()->SetDouble(1, request);
                  frame->SendProcessMessage(PID_RENDERER, msg);
                }];
  // A page that never answers (navigated away, hung) fails after 3 s.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   OEWebContent* content = weakSelf;
                   OEPiPCompletion pending = content.oe_mediaFrames.pipCallbacks[@(request)];
                   if (pending) {
                     [content.oe_mediaFrames.pipCallbacks removeObjectForKey:@(request)];
                     pending(NO);
                   }
                 });
}

- (void)exitPictureInPicturePausingVideo:(BOOL)pause {
  OEMediaSession* session = self.mediaSession;
  CefRefPtr<CefBrowser> browser = self.oe_browser;
  if (!session || !browser) {
    return;
  }
  for (NSString* frameId in self.oe_mediaFrames.states) {
    NSDictionary* f = self.oe_mediaFrames.states[frameId];
    if (![f[@"pip"] boolValue]) {
      continue;
    }
    CefRefPtr<CefFrame> frame = browser->GetFrameByIdentifier(OECef(frameId));
    if (!frame) {
      continue;
    }
    for (NSString* command in pause ? @[ @"exitpip", @"pause" ] : @[ @"exitpip" ]) {
      CefRefPtr<CefProcessMessage> msg =
          CefProcessMessage::Create(kOEMsgMediaCommand);
      msg->GetArgumentList()->SetString(0, OECef(command));
      msg->GetArgumentList()->SetDouble(1, 0);
      frame->SendProcessMessage(PID_RENDERER, msg);
    }
  }
}

@end
