// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_TAB_STRIP_OPEN_HOSTED_PLATFORM_DELEGATE_H_
#define OPEN_BROWSER_TAB_STRIP_OPEN_HOSTED_PLATFORM_DELEGATE_H_

#include <memory>

#include "cef/libcef/browser/chrome/browser_platform_delegate_chrome.h"

namespace open_engine {

// Platform delegate of a Chrome style browser that is a tab of an
// OpenTabStrip (a hosted tab). Chromium owns the WebContents through the
// strip's hidden Browser; the embedder puts the WebContents view, which is
// this browser's window handle, into its own NSView.
class OpenHostedPlatformDelegate : public CefBrowserPlatformDelegateChrome {
 public:
  OpenHostedPlatformDelegate(
      std::unique_ptr<CefBrowserPlatformDelegateNative> native_delegate,
      int strip_id);
  OpenHostedPlatformDelegate(const OpenHostedPlatformDelegate&) = delete;
  OpenHostedPlatformDelegate& operator=(const OpenHostedPlatformDelegate&) =
      delete;
  ~OpenHostedPlatformDelegate() override;

  // The strip id of |delegate| if it is a hosted tab's delegate, else 0.
  static int StripIdFor(const CefBrowserPlatformDelegate* delegate);

  int strip_id() const { return strip_id_; }

  // CefBrowserPlatformDelegate:
  CefWindowHandle GetHostWindowHandle() const override;
  void SetFocus(bool set_focus) override;
  bool IsPrintPreviewSupported() const override;
  void WasHidden(bool hidden) override;
  bool IsHidden() const override;

 private:
  const int strip_id_;
};

}  // namespace open_engine

#endif  // OPEN_BROWSER_TAB_STRIP_OPEN_HOSTED_PLATFORM_DELEGATE_H_
