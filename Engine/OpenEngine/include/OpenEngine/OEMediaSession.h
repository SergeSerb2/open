#import <AppKit/AppKit.h>
#import <OpenEngine/OEDefines.h>
#import <OpenEngine/OEWebContent.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

// Media state of one page (docs/plans/media-pip.md §6, EM-1a/EM-1b/EM-5).
// The shape is the fork's media session API. Until the fork patch lands the
// values come from an engine-owned probe in every frame (EM-1a): a page can
// fake them, so they drive UI only, never a security decision.

typedef NS_ENUM(NSInteger, OEMediaPlaybackState) {
  OEMediaPlaybackStateNone = 0,
  OEMediaPlaybackStatePaused,
  OEMediaPlaybackStatePlaying,
};

typedef NS_OPTIONS(NSUInteger, OEMediaActions) {
  OEMediaActionPlay = 1u << 0,
  OEMediaActionPause = 1u << 1,
  OEMediaActionPreviousTrack = 1u << 2,
  OEMediaActionNextTrack = 1u << 3,
  OEMediaActionSeekBackward = 1u << 4,
  OEMediaActionSeekForward = 1u << 5,
  OEMediaActionSeekTo = 1u << 6,
  OEMediaActionSkipAd = 1u << 7,
  OEMediaActionStop = 1u << 8,
  OEMediaActionEnterPictureInPicture = 1u << 9,
  OEMediaActionExitPictureInPicture = 1u << 10,
  /// The page registered an "enterpictureinpicture" handler: Chromium's
  /// own auto-PiP path owns it (media-pip §4.5.6).
  OEMediaActionEnterAutoPictureInPicture = 1u << 11,
  OEMediaActionToggleMicrophone = 1u << 12,
  OEMediaActionToggleCamera = 1u << 13,
  OEMediaActionHangUp = 1u << 14,
  OEMediaActionPreviousSlide = 1u << 15,
  OEMediaActionNextSlide = 1u << 16,
};

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEMediaPosition : NSObject
- (instancetype)init NS_UNAVAILABLE;
/// INFINITY for live streams; 0 when unknown.
@property(nonatomic, readonly) NSTimeInterval duration;
/// At lastUpdated.
@property(nonatomic, readonly) NSTimeInterval position;
@property(nonatomic, readonly) double playbackRate;
@property(nonatomic, readonly, copy) NSDate* lastUpdated;
@property(nonatomic, readonly, getter=isEndOfMedia) BOOL endOfMedia;
@end

/// A snapshot. The web content replaces it on every OEWebContentChangeMedia;
/// commands go to the page the snapshot came from.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEMediaSession : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly, weak, nullable) OEWebContent* webContent;
@property(nonatomic, readonly) OEMediaPlaybackState playbackState;
/// A player with sound that is not a short effect: the sidebar shows a
/// mini player only for a controllable session.
@property(nonatomic, readonly, getter=isControllable) BOOL controllable;
@property(nonatomic, readonly) BOOL hasVideo;
@property(nonatomic, readonly) BOOL hasAudio;
/// CSS px of the largest playing video (zero when none plays).
@property(nonatomic, readonly) CGSize largestVideoSize;
/// The largest playing video has the disablePictureInPicture attribute.
@property(nonatomic, readonly, getter=isPictureInPictureDisabled)
    BOOL pictureInPictureDisabled;
@property(nonatomic, readonly) OEMediaActions actions;
@property(nonatomic, readonly, copy, nullable) NSString* title;
@property(nonatomic, readonly, copy, nullable) NSString* artist;
@property(nonatomic, readonly, copy, nullable) NSString* album;
@property(nonatomic, readonly, nullable) OEMediaPosition* position;
/// A video of this page is in video Picture in Picture.
@property(nonatomic, readonly, getter=isPictureInPicture) BOOL pictureInPicture;
/// The page reports a meeting microphone/camera state; NO when unknown.
@property(nonatomic, readonly) BOOL microphoneMuted;
@property(nonatomic, readonly) BOOL cameraOn;
- (void)play;
- (void)pause;
- (void)previousTrack;
- (void)nextTrack;
- (void)seekBy:(NSTimeInterval)delta NS_SWIFT_NAME(seek(by:));
- (void)seekTo:(NSTimeInterval)time NS_SWIFT_NAME(seek(to:));
/// A seek during a drag (no final seek events). The probe seeks directly.
- (void)scrubTo:(NSTimeInterval)time NS_SWIFT_NAME(scrub(to:));
- (void)skipAd;
- (void)stop;
- (void)toggleMicrophone;
- (void)toggleCamera;
- (void)hangUp;
@end

@interface OEWebContent (Media)
/// nil until a frame of the page has played media.
@property(nonatomic, readonly, nullable) OEMediaSession* mediaSession;
/// Enters video Picture in Picture for the playing video with the largest
/// visible area (EM-5). Completion: YES when the page entered PiP.
- (void)requestPictureInPictureWithCompletion:
    (void (^NS_SWIFT_UI_ACTOR _Nullable)(BOOL entered))completion
    NS_SWIFT_NAME(requestPictureInPicture(completion:));
- (void)exitPictureInPicturePausingVideo:(BOOL)pause
    NS_SWIFT_NAME(exitPictureInPicture(pausing:));
@end

NS_HEADER_AUDIT_END(nullability, sendability)
