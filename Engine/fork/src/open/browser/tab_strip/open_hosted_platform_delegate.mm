// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/browser/tab_strip/open_hosted_platform_delegate.h"

#import <AppKit/AppKit.h>

#include "base/containers/flat_map.h"
#include "base/no_destructor.h"
#include "cef/include/internal/cef_types_mac.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"

namespace open_engine {

namespace {

// Live hosted delegates. Chromium builds without RTTI, so this map is how
// the CEF hooks tell a hosted tab from other Chrome style browsers.
base::flat_map<const CefBrowserPlatformDelegate*, int>& Delegates() {
  static base::NoDestructor<
      base::flat_map<const CefBrowserPlatformDelegate*, int>>
      delegates;
  return *delegates;
}

}  // namespace

OpenHostedPlatformDelegate::OpenHostedPlatformDelegate(
    std::unique_ptr<CefBrowserPlatformDelegateNative> native_delegate,
    int strip_id)
    : CefBrowserPlatformDelegateChrome(std::move(native_delegate)),
      strip_id_(strip_id) {
  Delegates()[this] = strip_id;
}

OpenHostedPlatformDelegate::~OpenHostedPlatformDelegate() {
  Delegates().erase(this);
}

// static
int OpenHostedPlatformDelegate::StripIdFor(
    const CefBrowserPlatformDelegate* delegate) {
  auto it = Delegates().find(delegate);
  return it == Delegates().end() ? 0 : it->second;
}

CefWindowHandle OpenHostedPlatformDelegate::GetHostWindowHandle() const {
  // The WebContents view itself; the embedder parents it.
  if (!web_contents_) {
    return kNullWindowHandle;
  }
  return CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(
      web_contents_->GetNativeView().GetNativeNSView());
}

void OpenHostedPlatformDelegate::SetFocus(bool set_focus) {
  if (set_focus && web_contents_) {
    web_contents_->Focus();
  }
}

void OpenHostedPlatformDelegate::WasHidden(bool hidden) {
  // Tabs that Chromium creates in the background start hidden, and the view
  // reports visible only when its window is not occluded. The embedder calls
  // this when it shows or hides the page's view; occlusion still applies
  // afterwards (WebContentsViewCocoa).
  if (!web_contents_) {
    return;
  }
  if (hidden) {
    web_contents_->WasHidden();
  } else {
    web_contents_->WasShown();
  }
}

bool OpenHostedPlatformDelegate::IsHidden() const {
  return web_contents_ &&
         web_contents_->GetVisibility() == content::Visibility::HIDDEN;
}

bool OpenHostedPlatformDelegate::IsPrintPreviewSupported() const {
  // Print preview is a tab-modal Views dialog; hidden Browsers have no
  // dialog host. Fall back to the system print dialog.
  return false;
}

}  // namespace open_engine
