// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "cef/include/cef_open_browser_info.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/browser_info.h"
#include "cef/libcef/browser/thread_util.h"

bool CefSetBrowserExtraInfo(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefDictionaryValue> extra_info) {
  CEF_REQUIRE_UIT_RETURN(false);
  auto host = browser ? CefBrowserHostBase::FromBrowser(browser) : nullptr;
  if (!host || !host->browser_info()->IsValid()) {
    return false;
  }
  return host->browser_info()->SetExtraInfo(extra_info);
}
