// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_MEDIA_OPEN_MEDIA_HOOKS_H_
#define OPEN_BROWSER_MEDIA_OPEN_MEDIA_HOOKS_H_

#include <memory>

namespace content {
class VideoOverlayWindow;
class VideoPictureInPictureWindowController;
class WebContents;
}  // namespace content

namespace open_engine {

// Fork hooks for Chrome code (Engine/fork/patches/chromium/0402-open-video-
// pip-window.patch, 0403-open-document-pip-window.patch). Chrome's targets do not link against Open's sources, so
// the overlay fills these in (OpenMediaController::GetOrCreate, before any
// page can enter Picture in Picture).
struct MediaHooks {
  // Open's window (OpenVideoOverlayWindow, EM-4) when the page's media handler
  // hosts video Picture in Picture itself, nullptr for Chromium's own window.
  std::unique_ptr<content::VideoOverlayWindow> (*create_video_overlay_window)(
      content::VideoPictureInPictureWindowController* controller) = nullptr;
  // EM-7: takes the Document Picture in Picture child |child| of |opener| and
  // shows it in the embedder's window (OpenDocumentPipHost) when the opener's
  // media handler hosts Picture in Picture. Returns false and leaves |child|
  // alone for Chromium's own window.
  bool (*host_document_picture_in_picture)(
      content::WebContents* opener,
      std::unique_ptr<content::WebContents>& child) = nullptr;
};

inline MediaHooks& GetMediaHooks() {
  static MediaHooks hooks;
  return hooks;
}

// The overlay's implementation of create_video_overlay_window.
std::unique_ptr<content::VideoOverlayWindow> MaybeCreateVideoOverlayWindow(
    content::VideoPictureInPictureWindowController* controller);

// The overlay's implementation of host_document_picture_in_picture.
bool MaybeHostDocumentPictureInPicture(
    content::WebContents* opener,
    std::unique_ptr<content::WebContents>& child);

}  // namespace open_engine

#endif  // OPEN_BROWSER_MEDIA_OPEN_MEDIA_HOOKS_H_
