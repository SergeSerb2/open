// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#ifndef CEF_INCLUDE_CEF_OPEN_OMNIBOX_H_
#define CEF_INCLUDE_CEF_OPEN_OMNIBOX_H_
#pragma once
#include "include/cef_api_hash.h"
#include "include/cef_base.h"
#include "include/cef_browser.h"
#include "include/cef_request_context.h"
#include "include/cef_values.h"
#if CEF_API_ADDED(CEF_EXPERIMENTAL)
///
/// Window-scoped omnibox replies. All calls are on the browser UI thread,
/// outside Chromium's observer notifications.
///
/*--cef(source=client,added=experimental)--*/
class CefOpenOmniboxHandler : public virtual CefBaseRefCounted {
 public:
  ///
  /// Latest input's first reply. Rows contain content, description, deletable,
  /// and match/dim/url lists of dictionaries with location and length in UTF-16.
  ///
  /*--cef()--*/
  virtual void OnSuggestions(int request_id, CefRefPtr<CefListValue> rows) {}
  ///
  /// The active extension's default suggestion may have changed.
  ///
  /*--cef()--*/
  virtual void OnDefaultChanged(const CefString& extension_id) {}
};
///
/// Omnibox event delivery without Chromium's autocomplete controller.
/// One object per embedder window. All methods run on the browser UI thread.
///
/*--cef(source=library,added=experimental)--*/
class CefOpenOmnibox : public virtual CefBaseRefCounted {
 public:
  ///
  /// Creates a window session for an initialized request context.
  ///
  /*--cef()--*/
  static CefRefPtr<CefOpenOmnibox> Create(CefRefPtr<CefRequestContext> context,
                                         CefRefPtr<CefOpenOmniboxHandler> handler);
  ///
  /// Cancels the current session and stops observations. Safe to repeat.
  ///
  /*--cef()--*/
  virtual void Close() = 0;
  ///
  /// Starts a keyword session of an enabled extension. Repeated start is a no-op.
  ///
  /*--cef()--*/
  virtual void Start(const CefString& extension_id) = 0;
  ///
  /// Sends input. Returns a negative request id, or zero without a listener.
  /// Supersedes previous requests. Only the first reply to the latest id is sent.
  ///
  /*--cef(optional_param=text)--*/
  virtual int InputChanged(const CefString& extension_id, const CefString& text) = 0;
  ///
  /// The parsed default suggestion; %s stays literal. Null when none is set.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefDictionaryValue> GetDefault(const CefString& extension_id) = 0;
  ///
  /// Accepts the input against the active tab. Disposition: 0 current, 1 new
  /// foreground, 2 new background. Ends the session without cancellation.
  ///
  /*--cef(optional_param=text)--*/
  virtual void Enter(const CefString& extension_id, const CefString& text,
                      CefRefPtr<CefBrowser> browser, int disposition) = 0;
  ///
  /// Ends a session, delivering onInputCancelled once.
  ///
  /*--cef()--*/
  virtual void Cancel(const CefString& extension_id) = 0;
  ///
  /// Deletes an extension suggestion.
  ///
  /*--cef(optional_param=content)--*/
  virtual void DeleteSuggestion(const CefString& extension_id, const CefString& content) = 0;
};
#endif
#endif
