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
// ---------------------------------------------------------------------------
//
// Open fork API for tab sleeping: freeze, discard in place, and the unload
// handler flag (docs/plans/memory-fork.md §5.4-§5.6, P-MEM-02, P-MEM-03,
// P-MEM-06). The contents of this file must follow a specific format in
// order to support the CEF translator tool. See the translator.README.txt
// file in the tools directory for more information.
//

#ifndef CEF_INCLUDE_CEF_PAGE_LIFECYCLE_H_
#define CEF_INCLUDE_CEF_PAGE_LIFECYCLE_H_
#pragma once

#include "include/cef_api_hash.h"
#include "include/cef_base.h"
#include "include/cef_browser.h"
#include "include/cef_callback.h"

#if CEF_API_ADDED(CEF_EXPERIMENTAL)

///
/// Freezes (|frozen| true) or unfreezes the page of |browser|. A frozen
/// renderer runs no timers, tasks or loads and keeps its memory. Only a page
/// that is not visible can be frozen (see CefBrowserHost::WasHidden); showing
/// a page unfreezes it. Returns false and changes nothing for a visible page
/// or a browser without a page. Must be called on the browser process UI
/// thread.
///
/*--cef(added=experimental)--*/
bool CefSetPageFrozen(CefRefPtr<CefBrowser> browser, bool frozen);

///
/// Returns true while the page of |browser| is frozen by CefSetPageFrozen.
/// False again after it is unfrozen, shown, discarded or closed. Must be
/// called on the browser process UI thread.
///
/*--cef(added=experimental)--*/
bool CefIsPageFrozen(CefRefPtr<CefBrowser> browser);

///
/// Discards the page of |browser| in place: its renderer and frame tree are
/// released; the browser, its navigation history and its tab identity stay.
/// The page reloads from its history entry when it is shown again, and that
/// document sees document.wasDiscarded == true. Only a page that is not
/// visible can be discarded. Returns true if the request was accepted (or
/// the page is discarded already), false if it was refused (visible page,
/// no page, or the WebContentsDiscard feature is off). |callback| runs
/// exactly once on the UI thread when the request settles, also when it was
/// refused or gave up: a navigation that is about to commit makes Chromium
/// ignore a discard, which is retried once after 100 ms. The callback does
/// not mean that the page was discarded: check CefWasDiscarded then. Must be
/// called on the browser process UI thread.
///
/*--cef(added=experimental,optional_param=callback)--*/
bool CefDiscardBrowser(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefCompletionCallback> callback);

///
/// Returns true if the page of |browser| is discarded (by CefDiscardBrowser,
/// or restored by CefRestoreNavigationHistory) and has not started loading
/// again. Must be called on the browser process UI thread.
///
/*--cef(added=experimental)--*/
bool CefWasDiscarded(CefRefPtr<CefBrowser> browser);

///
/// Returns true if the page of |browser| has beforeunload or unload handlers
/// that would run when it closes. Must be called on the browser process UI
/// thread.
///
/*--cef(added=experimental)--*/
bool CefHasUnloadHandlers(CefRefPtr<CefBrowser> browser);

#endif  // CEF_API_ADDED(CEF_EXPERIMENTAL)

#endif  // CEF_INCLUDE_CEF_PAGE_LIFECYCLE_H_
