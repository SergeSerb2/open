// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CEF_INCLUDE_CEF_SITE_CONTROL_H_
#define CEF_INCLUDE_CEF_SITE_CONTROL_H_
#pragma once

#include "include/cef_browser.h"
#include "include/cef_request_context.h"
#include "include/cef_values.h"

#if CEF_API_ADDED(CEF_EXPERIMENTAL)
///
/// Lists non-default per-origin content settings as dictionaries with the
/// registry's "kind" name and "state" (allow, block, ask or session). This
/// visits every registered scalar ContentSetting, including future types.
/// Empty for an invalid HTTP(S) origin or an uninitialized context. UI only.
///
/*--cef(added=experimental)--*/
CefRefPtr<CefListValue> CefGetChangedSiteSettings(
    CefRefPtr<CefRequestContext> request_context, const CefString& origin);

///
/// Sets one registered content setting. Rejects unknown kinds, states not
/// valid for that kind, invalid origins and uninitialized contexts. UI only.
///
/*--cef(added=experimental)--*/
bool CefSetSiteSetting(CefRefPtr<CefRequestContext> request_context,
                       const CefString& origin,
                       const CefString& kind,
                       const CefString& state);

///
/// Completion of one site-data removal. May close the context. UI thread.
///
/*--cef(source=client,added=experimental)--*/
class CefSiteDataCallback : public virtual CefBaseRefCounted {
 public:
  ///
  /// Called once, after every selected backend has finished. False indicates
  /// a backend failure; removal is not a transaction and may be partial.
  ///
  /*--cef()--*/
  virtual void OnComplete(bool success) = 0;
};

///
/// Removes selected data of one HTTP(S) origin: bits 1 cookies, 2 HTTP cache,
/// 4 storage. Cache and storage match the exact origin, in all storage-key
/// contexts. Cookies match the host, including parent Domain cookies; cookies
/// intrinsically share schemes/ports and a parent Domain cookie is shared.
/// No unrelated host-only cookie is removed. Unknown bits/origins return false
/// without invoking callback. Otherwise callback runs once on UI, possibly
/// synchronously. Safe before context initialization; holds the context alive.
///
/*--cef(added=experimental)--*/
bool CefClearSiteData(CefRefPtr<CefRequestContext> request_context,
                      const CefString& origin, int types,
                      CefRefPtr<CefSiteDataCallback> callback);

///
/// Current visible connection: secure, neutral, insecure, dangerous or
/// mixedContent. HTTP (including loopback) is insecure; non-network pages are
/// neutral. Major certificate errors and known malicious verdicts win over
/// mixed-content classification. Uses Chrome's current visible-security state.
/// Read again on CefOpenPageHandler::OnSecurityStateChanged. UI thread only.
///
/*--cef(added=experimental)--*/
CefString CefGetSiteSecurityLevel(CefRefPtr<CefBrowser> browser);
#endif
#endif  // CEF_INCLUDE_CEF_SITE_CONTROL_H_
