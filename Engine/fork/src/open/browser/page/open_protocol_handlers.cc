// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Web protocol handlers (navigator.registerProtocolHandler; PB1 2026-11-12,
// "Make <site> your default mail app?"). Chrome already does the work in
// hosted Open tabs: BrowserWebContentsDelegate::RegisterProtocolHandler queues
// a RegisterProtocolHandlerPermissionRequest (CEF reports it as
// CEF_PERMISSION_TYPE_REGISTER_PROTOCOL_HANDLER), a grant stores the handler
// in the Profile's ProtocolHandlerRegistry, and navigations to the scheme are
// translated. These functions only expose what the embedder cannot see: the
// pending request's scheme and URL (patch 0507 adds the accessor), and the
// registry (translate, list, remove).

#include <string>
#include <vector>

#include "cef/include/cef_open_page.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/request_context_impl.h"
#include "cef/libcef/browser/thread_util.h"
#include "chrome/browser/custom_handlers/protocol_handler_registry_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/custom_handlers/protocol_handler.h"
#include "components/custom_handlers/protocol_handler_registry.h"
#include "components/custom_handlers/register_protocol_handler_permission_request.h"
#include "components/permissions/permission_request.h"
#include "components/permissions/permission_request_manager.h"
#include "components/permissions/request_type.h"
#include "content/public/browser/web_contents.h"
#include "url/gurl.h"

namespace open_engine {

namespace {

custom_handlers::ProtocolHandlerRegistry* RegistryFor(
    CefRefPtr<CefRequestContext> request_context) {
  if (!request_context) {
    return nullptr;
  }
  auto* impl = static_cast<CefRequestContextImpl*>(request_context.get());
  if (!impl->VerifyBrowserContext()) {
    return nullptr;
  }
  Profile* profile = CefRequestContextImpl::GetProfile(request_context);
  // Chrome registers nothing off the record; the registry there is the
  // parent Profile's, read-only for pages.
  return profile ? ProtocolHandlerRegistryFactory::GetForBrowserContext(profile)
                 : nullptr;
}

CefRefPtr<CefDictionaryValue> ToValue(
    const custom_handlers::ProtocolHandler& handler,
    const custom_handlers::ProtocolHandlerRegistry* registry) {
  CefRefPtr<CefDictionaryValue> value = CefDictionaryValue::Create();
  value->SetString("scheme", handler.protocol());
  value->SetString("url", handler.url().spec());
  if (registry) {
    value->SetBool("default", registry->IsDefault(handler));
  }
  return value;
}

}  // namespace

}  // namespace open_engine

CefRefPtr<CefDictionaryValue> CefGetPendingProtocolHandlerRequest(
    CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  CefRefPtr<CefBrowserHostBase> host =
      CefBrowserHostBase::FromBrowser(browser);
  content::WebContents* web_contents = host ? host->GetWebContents() : nullptr;
  auto* manager =
      web_contents
          ? permissions::PermissionRequestManager::FromWebContents(web_contents)
          : nullptr;
  if (!manager) {
    return nullptr;
  }
  for (const auto& request : manager->Requests()) {
    if (request->request_type() ==
        permissions::RequestType::kRegisterProtocolHandler) {
      // Only RegisterProtocolHandlerPermissionRequest has this type.
      const auto* typed = static_cast<
          const custom_handlers::RegisterProtocolHandlerPermissionRequest*>(
          request.get());
      return open_engine::ToValue(typed->handler(), nullptr);
    }
  }
  return nullptr;
}

CefRefPtr<CefListValue> CefGetProtocolHandlers(
    CefRefPtr<CefRequestContext> request_context) {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  CefRefPtr<CefListValue> items = CefListValue::Create();
  auto* registry = open_engine::RegistryFor(request_context);
  if (!registry) {
    return items;
  }
  std::vector<std::string> schemes;
  registry->GetRegisteredProtocols(&schemes);
  for (const std::string& scheme : schemes) {
    for (const auto& handler : registry->GetHandlersFor(scheme)) {
      items->SetDictionary(items->GetSize(),
                           open_engine::ToValue(handler, registry));
    }
  }
  return items;
}

CefString CefTranslateProtocolHandlerURL(
    CefRefPtr<CefRequestContext> request_context,
    const CefString& url) {
  CEF_REQUIRE_UIT_RETURN(CefString());
  auto* registry = open_engine::RegistryFor(request_context);
  const GURL source(url.ToString());
  // Translate() CHECKs that the scheme has a handler.
  if (!registry || !source.is_valid() ||
      !registry->IsHandledProtocol(source.scheme())) {
    return CefString();
  }
  const GURL translated = registry->Translate(source);
  return translated.is_valid() ? CefString(translated.spec()) : CefString();
}

bool CefRemoveProtocolHandler(CefRefPtr<CefRequestContext> request_context,
                              const CefString& scheme,
                              const CefString& url) {
  CEF_REQUIRE_UIT_RETURN(false);
  auto* registry = open_engine::RegistryFor(request_context);
  if (!registry) {
    return false;
  }
  const std::string wanted_scheme = scheme.ToString();
  const GURL wanted_url(url.ToString());
  for (const auto& handler : registry->GetHandlersFor(wanted_scheme)) {
    if (handler.url() == wanted_url) {
      registry->RemoveHandler(handler);
      return true;
    }
  }
  return false;
}
