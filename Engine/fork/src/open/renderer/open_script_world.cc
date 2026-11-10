// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "cef/include/cef_open_world.h"
#include "cef/libcef/renderer/thread_util.h"
#include "cef/libcef/renderer/v8_impl.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "third_party/blink/public/platform/web_isolated_world_info.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/web_local_frame.h"
#include "third_party/blink/public/web/web_script_source.h"

bool CefIsPageScriptContext(CefRefPtr<CefV8Context> context) {
  CEF_REQUIRE_RT_RETURN(false);
  if (!context || !context->IsValid()) return false;
  auto* impl = static_cast<CefV8ContextImpl*>(context.get());
  auto* frame = impl->GetWebFrame();
  v8::HandleScope scope(v8::Isolate::GetCurrent());
  return frame && frame->GetScriptContextWorldId(impl->GetV8Context()) == 0;
}

CefRefPtr<CefV8Context> CefGetOpenScriptContext(
    CefRefPtr<CefV8Context> page_context) {
  CEF_REQUIRE_RT_RETURN(nullptr);
  if (!CefIsPageScriptContext(page_context)) return nullptr;
  auto* frame = static_cast<CefV8ContextImpl*>(page_context.get())->GetWebFrame();
  if (!frame) return nullptr;
  auto* isolate = v8::Isolate::GetCurrent();
  v8::HandleScope scope(isolate);
  auto context = frame->GetScriptContextFromWorldId(isolate,
                                                   ISOLATED_WORLD_ID_OPEN);
  if (context.IsEmpty()) {
    blink::WebIsolatedWorldInfo info;
    info.human_readable_name = blink::WebString::FromUtf8("Open");
    blink::SetIsolatedWorldInfo(ISOLATED_WORLD_ID_OPEN, info);
    // This enters Blink's normal isolated-world creation path for Open page
    // runtimes. The private cosmetic observer uses its own world (adblock
    // overlay, Chromium 0902), without the late cef.mojom frame pipe.
    frame->ExecuteScriptInIsolatedWorld(
        ISOLATED_WORLD_ID_OPEN,
        blink::WebScriptSource(blink::WebString::FromUtf8("void 0")),
        blink::BackForwardCacheAware::kAllow);
    context = frame->GetScriptContextFromWorldId(isolate, ISOLATED_WORLD_ID_OPEN);
  }
  return context.IsEmpty() ? nullptr : new CefV8ContextImpl(isolate, context);
}

bool CefIsOpenScriptContext(CefRefPtr<CefV8Context> context) {
  CEF_REQUIRE_RT_RETURN(false);
  if (!context || !context->IsValid()) return false;
  auto* impl = static_cast<CefV8ContextImpl*>(context.get());
  auto* frame = impl->GetWebFrame();
  v8::HandleScope scope(v8::Isolate::GetCurrent());
  return frame && frame->GetScriptContextWorldId(impl->GetV8Context()) ==
                      ISOLATED_WORLD_ID_OPEN;
}

CefString CefGetScriptDocumentIdentifier(CefRefPtr<CefV8Context> context) {
  CEF_REQUIRE_RT_RETURN(CefString());
  if (!context || !context->IsValid()) return CefString();
  auto* frame = static_cast<CefV8ContextImpl*>(context.get())->GetWebFrame();
  return frame ? CefString(frame->GetDocument().Token().ToString()) : CefString();
}
