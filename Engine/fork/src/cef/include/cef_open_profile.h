// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Open profile APIs. CEF's translator generates the C API and wrappers.
#ifndef CEF_INCLUDE_CEF_OPEN_PROFILE_H_
#define CEF_INCLUDE_CEF_OPEN_PROFILE_H_
#pragma once

#include "include/cef_api_hash.h"
#include "include/cef_base.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"

#if CEF_API_ADDED(CEF_EXPERIMENTAL)

///
/// Receives the end of a native profile's lifetime. Methods run on the UI
/// thread. Retaining a request context does not keep a primary OTR session live.
///
/*--cef(source=client,added=experimental)--*/
class CefOpenProfileHandler : public virtual CefBaseRefCounted {
 public:
  ///
  /// The native profile is closing. Stop using its request context immediately.
  ///
  /*--cef()--*/
  virtual void OnContextClosed() = 0;
};

///
/// Creates or shares the primary incognito session of an initialized regular
/// disk context, including Default. Returns nullptr for a missing, uninitialized,
/// closed, closing, private, guest or system parent, or if policy forbids standard
/// incognito. Never chooses a different parent or copies its cookies. Must run
/// on the UI thread. The last private Browser closes the session.
///
/*--cef(added=experimental,optional_param=handler)--*/
CefRefPtr<CefRequestContext> CefCreateIncognitoContext(
    CefRefPtr<CefRequestContext> original,
    CefRefPtr<CefRequestContextHandler> handler);

///
/// Returns whether an initialized request context still has a native profile.
/// Unlike CEF's normal profile accessors this fails closed without CHECKs.
/// Must run on the UI thread.
///
/*--cef(added=experimental)--*/
bool CefIsOpenProfileContextLive(CefRefPtr<CefRequestContext> context);

///
/// Observes the native profile's lifetime. An empty handler removes observation.
/// Returns false for an unavailable profile. Must run on the UI thread.
///
/*--cef(added=experimental,optional_param=handler)--*/
bool CefSetOpenProfileHandler(CefRefPtr<CefRequestContext> context,
                              CefRefPtr<CefOpenProfileHandler> handler);

///
/// Receives a browsing-data operation's completion on the UI thread.
///
/*--cef(source=client,added=experimental)--*/
class CefOpenProfileCallback : public virtual CefBaseRefCounted {
 public:
  ///
  /// Empty error means all requested backends completed successfully.
  ///
  /*--cef(optional_param=error)--*/
  virtual void OnComplete(const CefString& error) = 0;
};

///
/// Removes browsing data of exactly this profile for [begin, end] (end inclusive; Chromium semantics), expressed in
/// seconds since the Unix epoch. Kinds are bit 0 history, bit 1 cookies and site
/// data, bit 2 cache, bit 3 download records. Does not delete downloaded files.
/// Returns false for invalid arguments without running callback. Otherwise the
/// callback runs once after Chromium's remover completes. Must run on UI thread.
///
/*--cef(added=experimental)--*/
bool CefClearOpenProfileBrowsingData(CefRefPtr<CefRequestContext> context,
                                     int kinds,
                                     double begin,
                                     double end,
                                     CefRefPtr<CefOpenProfileCallback> callback);

///
/// Receives the two phases of ordered deletion. Must not retain the request
/// context while waiting for completion. All methods run on the UI thread.
///
/*--cef(source=client,added=experimental)--*/
class CefOpenProfileDeletionHandler : public virtual CefBaseRefCounted {
 public:
  ///
  /// Native WIPE_PROFILE removal completed. Close embedder managers and release
  /// every reference to every CEF context of this profile now.
  ///
  /*--cef()--*/
  virtual void OnReadyToRelease() = 0;

  ///
  /// Empty error means actual Profile destruction and Local State commit both
  /// completed. Only then may the embedder remove folders. An error leaves the
  /// folders intact. Error text contains no path or other profile data.
  ///
  /*--cef(optional_param=error)--*/
  virtual void OnComplete(const CefString& error) = 0;
};

///
/// Starts ordered deletion after the embedder closed all pages, private children,
/// Browsers, popups and downloads. Rejects Default and private contexts. Blocks
/// subsequent Open factories for this path, wipes native data, then asks for
/// release and waits for a late destructor sentinel. Never force-clears a
/// keep-alive and never removes profile folders. Returns false for invalid
/// arguments. Accepted operations call handler once even on failure.
///
/*--cef(added=experimental)--*/
bool CefDeleteOpenProfile(CefRefPtr<CefRequestContext> context,
                          CefRefPtr<CefOpenProfileDeletionHandler> handler);

#endif  // CEF_API_ADDED(CEF_EXPERIMENTAL)
#endif  // CEF_INCLUDE_CEF_OPEN_PROFILE_H_
