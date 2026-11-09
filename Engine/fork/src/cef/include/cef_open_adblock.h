// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CEF_INCLUDE_CEF_OPEN_ADBLOCK_H_
#define CEF_INCLUDE_CEF_OPEN_ADBLOCK_H_
#pragma once

#include <vector>
#include "include/cef_api_hash.h"
#include "include/cef_browser.h"
#include "include/cef_request_context.h"
#include "include/cef_values.h"

#if CEF_API_ADDED(CEF_EXPERIMENTAL)

///
/// Enables native ad blocking for this context (default false). Applies to
/// the next request. These APIs run on the browser-process UI thread and
/// reject missing, uninitialized or closed contexts. Never waits for a build.
/// Each off-the-record context has its own switch and exclusions; configure
/// it with its parent's list directory to share the immutable engine.
///
/*--cef(added=experimental)--*/
bool CefSetOpenAdBlockEnabled(CefRefPtr<CefRequestContext> request_context,
                               bool enabled);

///
/// Sets the adblock root containing current.json. Loads asynchronously on
/// the shared build runner. Empty unloads; the same directory is a no-op.
/// Must run on the browser-process UI thread.
///
/*--cef(added=experimental,optional_param=list_dir)--*/
bool CefSetOpenAdBlockListDirectory(
    CefRefPtr<CefRequestContext> request_context, const CefString& list_dir);

///
/// Re-reads current.json in the last directory after a new generation was
/// published. No-op without a directory. Must run on the UI thread.
///
/*--cef(added=experimental)--*/
bool CefReloadOpenAdBlockLists(CefRefPtr<CefRequestContext> request_context);

///
/// Replaces registrable-domain exclusions. Applies to the next request.
/// An empty vector clears exclusions. Must run on the UI thread.
///
/*--cef(added=experimental)--*/
bool CefSetOpenAdBlockExcludedDomains(
    CefRefPtr<CefRequestContext> request_context,
    const std::vector<CefString>& domains);

///
/// Returns a snapshot with enabled, engine_loaded, engine_from_dat,
/// engine_shared, dat_policy, list_count, resources_loaded, last_build_ms,
/// last_error, excluded_count and load_generation. Values are booleans,
/// numbers or strings. Contains no page URLs or paths. Returns nullptr for
/// an unavailable context. Must run on the UI thread.
///
/*--cef(added=experimental)--*/
CefRefPtr<CefDictionaryValue> CefGetOpenAdBlockStatus(
    CefRefPtr<CefRequestContext> request_context);

///
/// Returns blocked plus redirected subresources of this browser's current
/// main-frame document. Resets on navigation, survives same-document changes.
/// Returns zero without a tab helper. Must run on the UI thread.
///
/*--cef(added=experimental)--*/
int CefGetOpenAdBlockBlockedCount(CefRefPtr<CefBrowser> browser);

#endif  // CEF_API_ADDED(CEF_EXPERIMENTAL)
#endif  // CEF_INCLUDE_CEF_OPEN_ADBLOCK_H_
