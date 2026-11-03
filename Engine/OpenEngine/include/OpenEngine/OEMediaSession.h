#import <AppKit/AppKit.h>
#import <OpenEngine/OEDefines.h>
#import <OpenEngine/OEWebContent.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

// Media state of one page (docs/plans/media-pip.md §6, EM-1b/EM-2/EM-5),
// from the fork's CefMediaController (cef/include/cef_media_controller.h):
// Chromium's media session plus its players, all frames of the page. The
// page still shapes metadata and actions (navigator.mediaSession), so the
// values drive UI only, never a security decision.

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

/// A snapshot. The web content replaces it on every OEWebContentChangeMedia,
/// which fires at most once per real change (no playback timer: a position
/// change is a seek, a rate or duration change, or the end). Commands go to
/// the page the snapshot came from.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEMediaSession : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly, weak, nullable) OEWebContent* webContent;
@property(nonatomic, readonly) OEMediaPlaybackState playbackState;
/// Chromium's media session is controllable: a player with sound that is
/// not a short effect or a MediaStream. The sidebar shows a mini player only
/// for a controllable session. While the tab is muted (Chromium then leaves
/// its players out of the session) it keeps its last unmuted value.
@property(nonatomic, readonly, getter=isControllable) BOOL controllable;
@property(nonatomic, readonly) BOOL hasVideo;
@property(nonatomic, readonly) BOOL hasAudio;
/// Natural size in video pixels of the playing video with the largest
/// natural area (zero when none plays). Not CSS px: the browser does not
/// know element rects (Section 3 decision, docs/plans/media-pip.md Step 7).
@property(nonatomic, readonly) CGSize largestVideoSize;
/// That video cannot enter Picture in Picture: disablePictureInPicture, no
/// video track yet, or the frame's permissions policy.
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
/// The tab volume (OEWebContent.mediaVolume) when the snapshot was taken.
@property(nonatomic, readonly) double volume;
- (void)play;
- (void)pause;
- (void)previousTrack;
- (void)nextTrack;
- (void)seekBy:(NSTimeInterval)delta NS_SWIFT_NAME(seek(by:));
- (void)seekTo:(NSTimeInterval)time NS_SWIFT_NAME(seek(to:));
/// A seek during a drag (fast seek; no final seek events).
- (void)scrubTo:(NSTimeInterval)time NS_SWIFT_NAME(scrub(to:));
- (void)skipAd;
- (void)stop;
- (void)toggleMicrophone;
- (void)toggleCamera;
- (void)hangUp;
@end

@interface OEWebContent (Media)
/// nil until a player of the page has played (and again once none is
/// playing or paused mid-way).
@property(nonatomic, readonly, nullable) OEMediaSession* mediaSession;
/// Tab volume, 0...1 (default 1; not persisted). Scales every media element
/// of the page, later ones too (EM-2). Web Audio is not affected; use
/// `muted` for silence.
@property(nonatomic) double mediaVolume;
/// Enters video Picture in Picture for the playing video with the largest
/// natural area, without a user gesture (EM-5; largestVideoSize). Fails for
/// a video that cannot enter PiP (pictureInPictureDisabled). Completion: YES
/// when the page entered PiP, NO otherwise (after at most 2 s).
- (void)requestPictureInPictureWithCompletion:
    (void (^NS_SWIFT_UI_ACTOR _Nullable)(BOOL entered))completion
    NS_SWIFT_NAME(requestPictureInPicture(completion:));
- (void)exitPictureInPicturePausingVideo:(BOOL)pause
    NS_SWIFT_NAME(exitPictureInPicture(pausing:));
@end

NS_HEADER_AUDIT_END(nullability, sendability)
