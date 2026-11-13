// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/browser/tab_strip/open_devtools_dock.h"

#include <map>

#include "base/no_destructor.h"
#include "cef/include/cef_open_page.h"
#include "cef/libcef/browser/thread_util.h"

namespace open_engine {

namespace {

std::map<int, CefRefPtr<CefBrowserViewDelegate>>& Delegates() {
  static base::NoDestructor<std::map<int, CefRefPtr<CefBrowserViewDelegate>>>
      delegates;
  return *delegates;
}

}  // namespace

CefRefPtr<CefBrowserViewDelegate> TakeDevToolsDockDelegate(int browser_id) {
  auto& delegates = Delegates();
  auto it = delegates.find(browser_id);
  if (it == delegates.end()) {
    return nullptr;
  }
  CefRefPtr<CefBrowserViewDelegate> delegate = it->second;
  delegates.erase(it);
  return delegate;
}

}  // namespace open_engine

bool CefSetOpenDevToolsDockDelegate(CefRefPtr<CefBrowser> browser,
                                    CefRefPtr<CefBrowserViewDelegate> delegate) {
  CEF_REQUIRE_UIT_RETURN(false);
  if (!browser) {
    return false;
  }
  auto& delegates = open_engine::Delegates();
  if (delegate) {
    delegates[browser->GetIdentifier()] = delegate;
  } else {
    delegates.erase(browser->GetIdentifier());
  }
  return true;
}
