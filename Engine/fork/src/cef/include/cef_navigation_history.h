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
// Open fork API for tab sleeping: capture and restore of navigation history
// (docs/plans/memory-fork.md §5.3, P-MEM-04). The contents of this file must
// follow a specific format in order to support the CEF translator tool. See
// the translator.README.txt file in the tools directory for more
// information.
//

#ifndef CEF_INCLUDE_CEF_NAVIGATION_HISTORY_H_
#define CEF_INCLUDE_CEF_NAVIGATION_HISTORY_H_
#pragma once

#include "include/cef_api_hash.h"
#include "include/cef_base.h"
#include "include/cef_browser.h"
#include "include/cef_values.h"

#if CEF_API_ADDED(CEF_EXPERIMENTAL)

///
/// A browser's back/forward list as opaque entries: one Chromium session
/// pickle (sessions::SerializedNavigationEntry) per entry, in back-to-forward
/// order. The bytes are tied to the engine's Chromium version; a decode
/// failure after an engine update makes CefRestoreNavigationHistory return
/// false. The object is immutable and may be used on any thread.
///
/*--cef(source=library,added=experimental)--*/
class CefNavigationHistory : public virtual CefBaseRefCounted {
 public:
  ///
  /// Creates a history for CefRestoreNavigationHistory from |entries| (one
  /// binary value per entry, in back-to-forward order, as returned by
  /// GetEntryAt) and the index of the current entry. |has_page_state| tells
  /// whether the entries carry scroll and form state. Returns nullptr if
  /// |entries| is empty or has more than 512 entries, an entry is not a
  /// non-empty binary value, |current_index| is out of range, or the entries
  /// are larger than 2 MiB in total.
  ///
  /*--cef()--*/
  static CefRefPtr<CefNavigationHistory> Create(
      CefRefPtr<CefListValue> entries,
      int current_index,
      bool has_page_state);

  ///
  /// Returns the number of entries (at least 1).
  ///
  /*--cef()--*/
  virtual int GetEntryCount() = 0;

  ///
  /// Returns a copy of the entry at |index|, or nullptr if out of range.
  ///
  /*--cef(index_param=index)--*/
  virtual CefRefPtr<CefBinaryValue> GetEntryAt(int index) = 0;

  ///
  /// Returns the index of the current entry.
  ///
  /*--cef()--*/
  virtual int GetCurrentIndex() = 0;

  ///
  /// Returns the virtual URL of the current entry at capture time. Empty for
  /// created histories.
  ///
  /*--cef()--*/
  virtual CefString GetCurrentURL() = 0;

  ///
  /// Returns the title of the current entry at capture time. Empty for
  /// created histories.
  ///
  /*--cef()--*/
  virtual CefString GetTitle() = 0;

  ///
  /// Returns the favicon URL of the current entry at capture time. Empty if
  /// it has none, and for created histories.
  ///
  /*--cef()--*/
  virtual CefString GetFaviconURL() = 0;

  ///
  /// Returns true if the entries carry page state (scroll position and form
  /// values). False when the capture dropped it to stay under 2 MiB.
  ///
  /*--cef()--*/
  virtual bool HasPageState() = 0;
};

///
/// Captures the full back/forward list of |browser|, with scroll and form
/// state, in the browser process. The renderer is not contacted, so this
/// works for frozen, discarded and crashed pages. Returns nullptr if the
/// browser has no page, has not committed a navigation, or its history stays
/// over 2 MiB even without page state. Must be called on the browser process
/// UI thread.
///
/*--cef(added=experimental)--*/
CefRefPtr<CefNavigationHistory> CefGetNavigationHistory(
    CefRefPtr<CefBrowser> browser);

///
/// Installs |history| on |browser|, which must be unused: created with the
/// no_renderer browser setting, or with no navigation yet. Returns false
/// and changes nothing if the browser already has a committed or pending
/// navigation, or if an entry fails to decode. On success the current entry
/// loads when the page is shown (at once if it is visible already), its
/// document sees document.wasDiscarded == true, and back and forward reach
/// the restored entries. Must be called on the browser process UI thread.
///
/*--cef(added=experimental)--*/
bool CefRestoreNavigationHistory(CefRefPtr<CefBrowser> browser,
                                 CefRefPtr<CefNavigationHistory> history);

#endif  // CEF_API_ADDED(CEF_EXPERIMENTAL)

#endif  // CEF_INCLUDE_CEF_NAVIGATION_HISTORY_H_
