// OEPictureInPicture (media-pip EM-4). The fork's VideoOverlayWindow
// implementation creates these objects; until it lands no PiP opens through
// the delegate and Chromium's own window is used.

#import "OEInternal.h"

@implementation OEPictureInPicture
@end

@implementation OEEngine (PictureInPicture)

static __weak id<OEPictureInPictureDelegate> gPictureInPictureDelegate;

- (nullable id<OEPictureInPictureDelegate>)pictureInPictureDelegate {
  return gPictureInPictureDelegate;
}

- (void)setPictureInPictureDelegate:(nullable id<OEPictureInPictureDelegate>)delegate {
  gPictureInPictureDelegate = delegate;
}

- (BOOL)supportsShellPictureInPicture {
  return NO;
}

@end
