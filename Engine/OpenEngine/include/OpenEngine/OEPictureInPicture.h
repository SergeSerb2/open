#import <AppKit/AppKit.h>
#import <OpenEngine/OEDefines.h>
#import <OpenEngine/OEEngine.h>
#import <OpenEngine/OEMediaSession.h>
#import <OpenEngine/OEWebContent.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

// Video Picture in Picture in the shell's own window (docs/plans/media-pip.md
// §6 EM-4, phase 2). The engine hands the shell an NSView that shows the PiP
// video; the shell puts it in its window and draws its own controls.
//
// Opt-in: while OEEngine.pictureInPictureDelegate is set, a video PiP opens
// through the delegate instead of Chromium's own window. Without a delegate
// (or without the fork's EM-4 support) Chromium's window is used (phase 1).

typedef NS_ENUM(NSInteger, OEPictureInPicturePlaybackState) {
  OEPictureInPicturePlaybackStatePlaying = 0,
  OEPictureInPicturePlaybackStatePaused,
  OEPictureInPicturePlaybackStateEndOfVideo,
};

/// Controls the page offers in PiP (Chromium's VideoOverlayWindow setters).
typedef NS_OPTIONS(NSUInteger, OEPictureInPictureControls) {
  OEPictureInPictureControlPlayPause = 1u << 0,
  OEPictureInPictureControlNextTrack = 1u << 1,
  OEPictureInPictureControlPreviousTrack = 1u << 2,
  OEPictureInPictureControlSkipAd = 1u << 3,
  OEPictureInPictureControlToggleMicrophone = 1u << 4,
  OEPictureInPictureControlToggleCamera = 1u << 5,
  OEPictureInPictureControlHangUp = 1u << 6,
  OEPictureInPictureControlNextSlide = 1u << 7,
  OEPictureInPictureControlPreviousSlide = 1u << 8,
};

typedef NS_OPTIONS(NSUInteger, OEPictureInPictureChange) {
  OEPictureInPictureChangeNaturalSize = 1u << 0,
  OEPictureInPictureChangePlayback = 1u << 1,
  OEPictureInPictureChangeControls = 1u << 2,
  OEPictureInPictureChangePosition = 1u << 3,
  OEPictureInPictureChangeSourceTitle = 1u << 4,
  OEPictureInPictureChangeFavicon = 1u << 5,
  OEPictureInPictureChangeMeeting = 1u << 6,
  OEPictureInPictureChangeMuted = 1u << 7,
};

/// One open video PiP. Chromium allows one at a time.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEPictureInPicture : NSObject
- (instancetype)init NS_UNAVAILABLE;
/// The page whose video plays here; nil after it closed.
@property(nonatomic, readonly, weak, nullable) OEWebContent* webContent;
/// Shows the video. Put it in one window; the engine draws into it.
@property(nonatomic, readonly) NSView* videoView;
/// The video's natural size (pixels); zero until known.
@property(nonatomic, readonly) CGSize naturalSize;
/// The video element's rect in webContent.view coordinates when PiP started;
/// zero when unknown.
@property(nonatomic, readonly) CGRect sourceBounds;
@property(nonatomic, readonly) OEPictureInPicturePlaybackState playbackState;
@property(nonatomic, readonly) OEPictureInPictureControls controls;
@property(nonatomic, readonly) BOOL microphoneMuted;
@property(nonatomic, readonly) BOOL cameraOn;
/// The page's media is muted (tab mute or the PiP mute).
@property(nonatomic, readonly) BOOL mediaMuted;
/// Duration INFINITY for live streams; nil when the page reports none.
@property(nonatomic, readonly, nullable) OEMediaPosition* position;
@property(nonatomic, readonly, copy) NSString* sourceTitle;
@property(nonatomic, readonly, nullable) NSImage* favicon;
/// The shell reports its window frame (screen coordinates) and visibility.
/// Set windowFrame inside -pictureInPictureDidOpen: (Chromium reads the size
/// while PiP starts).
@property(nonatomic) CGRect windowFrame;
@property(nonatomic, getter=isWindowVisible) BOOL windowVisible;
- (void)togglePlayPause;
- (void)nextTrack;
- (void)previousTrack;
- (void)skipAd;
- (void)toggleMicrophone;
- (void)toggleCamera;
- (void)hangUp;
- (void)nextSlide;
- (void)previousSlide;
- (void)seekTo:(NSTimeInterval)time NS_SWIFT_NAME(seek(to:));
- (void)setMuted:(BOOL)muted;
/// Ends PiP; the video returns to the page. Never call it from inside a
/// delegate callback of this object (defer to the next run-loop turn).
- (void)closePausingVideo:(BOOL)pause NS_SWIFT_NAME(close(pausingVideo:));
/// The composited picture of `videoView` (the video and its letterbox) as PNG
/// data, from the engine's compositor, not from the screen. Nil if the session
/// ended or the copy failed; also nil after 2 s without an answer. For
/// automation checks and thumbnails.
- (void)captureVideoFrameWithCompletion:(void (^)(NSData* _Nullable png))completion
    NS_SWIFT_NAME(captureVideoFrame(completion:));
@end

NS_SWIFT_UI_ACTOR
@protocol OEPictureInPictureDelegate <NSObject>
/// A video PiP started. Create the window now and set windowFrame before
/// returning.
- (void)pictureInPictureDidOpen:(OEPictureInPicture*)pictureInPicture
    NS_SWIFT_NAME(pictureInPictureDidOpen(_:));
- (void)pictureInPicture:(OEPictureInPicture*)pictureInPicture
               didChange:(OEPictureInPictureChange)changes
    NS_SWIFT_NAME(pictureInPicture(_:didChange:));
/// PiP ended for any reason (page, navigation, close, crash, a new PiP).
/// The object is inert afterwards.
- (void)pictureInPictureDidClose:(OEPictureInPicture*)pictureInPicture
    NS_SWIFT_NAME(pictureInPictureDidClose(_:));
@end

@interface OEEngine (PictureInPicture)
/// Set it to host video PiP in the shell's window (phase 2).
@property(nonatomic, weak, nullable) id<OEPictureInPictureDelegate> pictureInPictureDelegate;
/// YES when this engine build can host video PiP in the shell (fork EM-4).
@property(nonatomic, readonly) BOOL supportsShellPictureInPicture;
/// YES when a Document PiP child can live in the shell's panel (fork EM-7).
/// Without it, answer OEOpenDispositionNewPictureInPicture with nil.
@property(nonatomic, readonly) BOOL supportsShellDocumentPictureInPicture;
@end

@interface OEWebContent (DocumentPictureInPicture)
/// For a Document PiP child: the size the page asked for (CSS px); zero until
/// known. Changes come with OEWebContentChangePictureInPicture.
@property(nonatomic, readonly) CGSize requestedPictureInPictureSize;
@end

NS_HEADER_AUDIT_END(nullability, sendability)
