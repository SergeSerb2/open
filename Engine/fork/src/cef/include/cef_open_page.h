// Copyright (c) 2026 The Open Authors. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the name Chromium Embedded
// Framework nor the names of its contributors may be used to endorse
// or promote products derived from this software without specific prior
// written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//
// ---------------------------------------------------------------------------
//
// Open fork API for page features (docs/plans/page-platform.md §6, fork series
// 05xx): history swipe events and options (EP-1, 0501), the page selection and
// its link to highlight (EP-2, EP-3; overlay only), web notification clicks
// and test hooks (EP-6, EP-7, 0504), and the website color scheme of a
// request context (EP-9b, 0505). The contents of this file must follow a specific format in order to support the
// CEF translator tool. See the translator.README.txt file in the tools
// directory for more information.
//

#ifndef CEF_INCLUDE_CEF_OPEN_PAGE_H_
#define CEF_INCLUDE_CEF_OPEN_PAGE_H_
#pragma once

#include "include/cef_api_hash.h"
#include "include/cef_base.h"
#include "include/cef_browser.h"
#include "include/cef_request_context.h"
#include "include/cef_values.h"

#if CEF_API_ADDED(CEF_EXPERIMENTAL)

///
/// Receives page events of one browser that CEF's handlers do not report.
/// Set with CefSetOpenPageHandler. Methods are called on the browser process
/// UI thread.
///
/*--cef(source=client,added=experimental)--*/
class CefOpenPageHandler : public virtual CefBaseRefCounted {
 public:
  ///
  /// The page's text selection became empty (|has_selection| false) or
  /// non-empty (true). Not called for caret moves that keep that state.
  ///
  /*--cef()--*/
  virtual void OnSelectionChanged(CefRefPtr<CefBrowser> browser,
                                  bool has_selection) {}

  ///
  /// Chromium's history swiper changed state. |phase| is 0 began, 1 changed,
  /// 2 completed (the swipe navigates), 3 cancelled. |direction| is 0 back,
  /// 1 forward. |progress| is 0 to 1; 1 means the swipe navigates when the
  /// gesture ends.
  ///
  /*--cef()--*/
  virtual void OnHistorySwipe(CefRefPtr<CefBrowser> browser,
                              int phase,
                              int direction,
                              double progress) {}
};

///
/// Sets (or, with an empty |handler|, removes) the page handler of |browser|.
/// Returns false for a browser without a page. Must be called on the browser
/// process UI thread.
///
/*--cef(added=experimental,optional_param=handler)--*/
bool CefSetOpenPageHandler(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefOpenPageHandler> handler);

///
/// Returns true if the page of |browser| has a non-empty text selection (the
/// state of the last CefOpenPageHandler::OnSelectionChanged). Must be called
/// on the browser process UI thread.
///
/*--cef(added=experimental)--*/
bool CefHasSelection(CefRefPtr<CefBrowser> browser);

///
/// Receives the result of CefRequestSelection.
///
/*--cef(source=client,added=experimental)--*/
class CefSelectionCallback : public virtual CefBaseRefCounted {
 public:
  ///
  /// |text| is the selected text of the focused frame (empty if nothing is
  /// selected). |link| is the page URL with a text-fragment directive that
  /// scrolls to the selection, or empty when Chromium could not make a unique
  /// one or the selection is inside a child frame.
  ///
  /*--cef(optional_param=text,optional_param=link)--*/
  virtual void OnSelection(const CefString& text, const CefString& link) = 0;
};

///
/// Requests the selection of |browser|'s focused frame and a link to it.
/// |callback| runs exactly once on the UI thread, also when the page closes
/// or the link generator fails (then |link| is empty). Returns false (and
/// does not run |callback|) for a browser without a page. Must be called on
/// the browser process UI thread.
///
/*--cef(added=experimental)--*/
bool CefRequestSelection(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefSelectionCallback> callback);

///
/// History swipe options of |browser|: |enabled| false makes Chromium's
/// swiper ignore gestures on this page; |draws_overlay| false hides
/// Chromium's own arrow overlay (the embedder draws its own from
/// CefOpenPageHandler::OnHistorySwipe). Both default to true. Returns false
/// for a browser without a page. Must be called on the browser process UI
/// thread.
///
/*--cef(added=experimental)--*/
bool CefSetHistorySwipeOptions(CefRefPtr<CefBrowser> browser,
                               bool enabled,
                               bool draws_overlay);

///
/// Test hook, active only when the browser process runs with the
/// --open-automation switch: replays one history swipe on |browser| through
/// Chromium's overlay controller (the path of a real trackpad or Magic Mouse
/// swipe after Chromium recognized the gesture): began, changed up to
/// |progress|, then completed (|progress| >= 1: the page navigates back
/// (|direction| 0) or forward (1)) or cancelled. Nothing happens and false is
/// returned when the hook is off, the page refuses swipes
/// (CefSetHistorySwipeOptions), or it cannot navigate in that direction.
/// Gesture recognition itself is Chromium's and is not replayed. Must be
/// called on the browser process UI thread.
///
/*--cef(added=experimental)--*/
bool CefSimulateHistorySwipe(CefRefPtr<CefBrowser> browser,
                             int direction,
                             double progress);

///
/// Receives web notification clicks of one request context.
///
/*--cef(source=client,added=experimental)--*/
class CefOpenNotificationHandler : public virtual CefBaseRefCounted {
 public:
  ///
  /// The user clicked a web notification (body or button) of the context,
  /// before Chromium dispatches the click to the page. |browser| is the page
  /// that created a non-persistent notification while that document lives;
  /// empty for service worker notifications and gone documents.
  ///
  /*--cef(optional_param=browser)--*/
  virtual void OnNotificationClick(const CefString& id,
                                   const CefString& origin,
                                   CefRefPtr<CefBrowser> browser,
                                   bool persistent) {}
};

///
/// Sets (or, with an empty |handler|, removes) the notification handler of
/// |request_context|. Returns false if the context is empty. Must be called
/// on the browser process UI thread.
///
/*--cef(added=experimental,optional_param=handler)--*/
bool CefSetOpenNotificationHandler(
    CefRefPtr<CefRequestContext> request_context,
    CefRefPtr<CefOpenNotificationHandler> handler);

///
/// Receives the result of CefGetDisplayedNotifications.
///
/*--cef(source=client,added=experimental)--*/
class CefNotificationListCallback : public virtual CefBaseRefCounted {
 public:
  ///
  /// |items| holds one dictionary per notification with the string keys
  /// "id", "origin", "title" and "body".
  ///
  /*--cef()--*/
  virtual void OnNotifications(CefRefPtr<CefListValue> items) = 0;
};

///
/// Test hook, active only when the browser process runs with the
/// --open-automation switch: lists the web notifications Chromium showed for
/// |request_context| (its display service; not the operating system's list, so
/// the hook works without notification authorization). A notification closed
/// by its page stays listed. Otherwise the list is empty. |callback| runs exactly
/// once on the UI thread. Must be called on the browser process UI thread.
///
/*--cef(added=experimental)--*/
bool CefGetDisplayedNotifications(
    CefRefPtr<CefRequestContext> request_context,
    CefRefPtr<CefNotificationListCallback> callback);

///
/// Test hook, active only with --open-automation: clicks the notification
/// |id| of |request_context| through the same path as a real click after
/// macOS hands the response to Chromium. Returns false if the hook is off or
/// the context is empty. Must be called on the browser process UI thread.
///
/*--cef(added=experimental)--*/
bool CefSimulateNotificationClick(CefRefPtr<CefRequestContext> request_context,
                                  const CefString& id);

///
/// Sets the color scheme that web pages of |request_context| see through
/// `prefers-color-scheme` and in their root scrollbar: CEF_COLOR_VARIANT_LIGHT
/// or CEF_COLOR_VARIANT_DARK force it, any other value (for example
/// CEF_COLOR_VARIANT_SYSTEM) removes the override, so pages follow Chromium's
/// own rule again. Live pages of the context update at once; DevTools and
/// chrome:// pages are not changed. Returns false if |request_context| is
/// empty. Applies when the context finishes initializing if it has not yet.
/// Must be called on the browser process UI thread.
///
/*--cef(added=experimental)--*/
bool CefSetWebsiteColorScheme(CefRefPtr<CefRequestContext> request_context,
                              cef_color_variant_t variant);

#endif  // CEF_API_ADDED(CEF_EXPERIMENTAL)

#endif  // CEF_INCLUDE_CEF_OPEN_PAGE_H_
