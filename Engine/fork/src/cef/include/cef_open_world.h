// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CEF_INCLUDE_CEF_OPEN_WORLD_H_
#define CEF_INCLUDE_CEF_OPEN_WORLD_H_
#pragma once

#include "include/cef_v8.h"

#if CEF_API_ADDED(CEF_EXPERIMENTAL)
///
/// Returns whether |context| belongs to the page's main world. Renderer
/// thread only. Unlike OnContextCreated, this excludes extension worlds.
///
/*--cef(added=experimental)--*/
bool CefIsPageScriptContext(CefRefPtr<CefV8Context> context);

///
/// Returns whether |context| belongs to Open's reserved world. Renderer only.
///
/*--cef(added=experimental)--*/
bool CefIsOpenScriptContext(CefRefPtr<CefV8Context> context);

///
/// Gets or creates Open's fixed isolated world in |page_context|'s current
/// frame and document. Returns empty for invalid contexts. Renderer thread only. Creation runs no page code and
/// grants no user gesture. Call at main-world OnContextCreated for
/// document-start delivery. All Open runtimes share this world; extension
/// worlds and the page have separate globals and DOM wrappers.
///
/*--cef(added=experimental)--*/
CefRefPtr<CefV8Context> CefGetOpenScriptContext(
    CefRefPtr<CefV8Context> page_context);

///
/// Chromium's document token of |context|'s frame, or empty for an invalid
/// context. Renderer thread only. Same-document navigation keeps the token.
///
/*--cef(added=experimental)--*/
CefString CefGetScriptDocumentIdentifier(CefRefPtr<CefV8Context> context);
#endif

#endif  // CEF_INCLUDE_CEF_OPEN_WORLD_H_
