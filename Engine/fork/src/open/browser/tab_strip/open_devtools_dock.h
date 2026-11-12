// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_TAB_STRIP_OPEN_DEVTOOLS_DOCK_H_
#define OPEN_BROWSER_TAB_STRIP_OPEN_DEVTOOLS_DOCK_H_

#include "cef/include/views/cef_browser_view_delegate.h"

namespace open_engine {

// DevTools docked in the embedder's view (IMC 10:55, 2026-11-12). The
// embedder registers a BrowserView delegate for an inspected browser with
// CefSetOpenDevToolsDockDelegate; the next DevTools browser created for it
// takes the delegate (ChromeBrowserDelegate::CreateDevToolsBrowser, CEF patch
// 0302) and is created as a Views-hosted popup, so the delegate receives its
// CefBrowserView in OnPopupBrowserViewCreated(is_devtools=true). Returns null
// when nothing is registered. Browser process UI thread.
CefRefPtr<CefBrowserViewDelegate> TakeDevToolsDockDelegate(int browser_id);

}  // namespace open_engine

#endif  // OPEN_BROWSER_TAB_STRIP_OPEN_DEVTOOLS_DOCK_H_
