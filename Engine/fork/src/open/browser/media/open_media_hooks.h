// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_MEDIA_OPEN_MEDIA_HOOKS_H_
#define OPEN_BROWSER_MEDIA_OPEN_MEDIA_HOOKS_H_

#include <memory>

namespace content {
class VideoOverlayWindow;
class VideoPictureInPictureWindowController;
}  // namespace content

namespace open_engine {

// Fork hooks for Chrome code (Engine/fork/patches/chromium/0402-open-video-
// pip-window.patch). Chrome's targets do not link against Open's sources, so
// the overlay fills these in (OpenMediaController::GetOrCreate, before any
// page can enter Picture in Picture).
struct MediaHooks {
  // Open's window (OpenVideoOverlayWindow, EM-4) when the page's media handler
  // hosts video Picture in Picture itself, nullptr for Chromium's own window.
  std::unique_ptr<content::VideoOverlayWindow> (*create_video_overlay_window)(
      content::VideoPictureInPictureWindowController* controller) = nullptr;
};

inline MediaHooks& GetMediaHooks() {
  static MediaHooks hooks;
  return hooks;
}

// The overlay's implementation of create_video_overlay_window.
std::unique_ptr<content::VideoOverlayWindow> MaybeCreateVideoOverlayWindow(
    content::VideoPictureInPictureWindowController* controller);

}  // namespace open_engine

#endif  // OPEN_BROWSER_MEDIA_OPEN_MEDIA_HOOKS_H_
