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

// Fork hook (Engine/fork/patches/cef/0401-open-media-hooks.patch, called from
// ChromeContentBrowserClientCef::CreateWindowForVideoPictureInPicture): Open's
// window (OpenVideoOverlayWindow, EM-4) when the page's media handler hosts
// video Picture in Picture itself, nullptr for Chromium's own window.
std::unique_ptr<content::VideoOverlayWindow> MaybeCreateVideoOverlayWindow(
    content::VideoPictureInPictureWindowController* controller);

}  // namespace open_engine

#endif  // OPEN_BROWSER_MEDIA_OPEN_MEDIA_HOOKS_H_
