// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CEF_INCLUDE_CEF_OPEN_BROWSER_INFO_H_
#define CEF_INCLUDE_CEF_OPEN_BROWSER_INFO_H_
#pragma once

#include "include/cef_browser.h"
#include "include/cef_values.h"

#if CEF_API_ADDED(CEF_EXPERIMENTAL)
///
/// Replaces the stored extra information for |browser| with a read-only copy
/// of |extra_info|. NULL clears it. Future renderer processes receive this
/// snapshot in OnBrowserCreated before their first script context is created.
/// Does not update a renderer that already exists; the client must send that
/// update separately. UI thread only. Returns false for a closing or invalid
/// browser, or if the dictionary cannot be copied.
///
/*--cef(added=experimental,optional_param=extra_info)--*/
bool CefSetBrowserExtraInfo(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefDictionaryValue> extra_info);
#endif

#endif  // CEF_INCLUDE_CEF_OPEN_BROWSER_INFO_H_
