// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "cef/include/cef_open_adblock.h"

#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "cef/libcef/browser/browser_context.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/request_context_impl.h"
#include "cef/libcef/browser/thread_util.h"
#include "chrome/browser/profiles/profile.h"
#include "components/web_cache/browser/web_cache_manager.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "open/adblock/open_adblock_cache.h"
#include "open/adblock/open_adblock_service.h"
#include "open/adblock/open_adblock_tab_helper.h"

namespace {

int ClearRendererCachesOnNavigation(CefBrowserContext::Getter context_getter) {
  CEF_REQUIRE_UIT_RETURN(0);
  auto* context = context_getter.Run();
  auto* owner = context ? context->AsBrowserContext() : nullptr;
  if (!owner || owner->ShutdownStarted()) {
    return 0;
  }
  auto* profile = context->AsProfile();
  auto* cache = web_cache::WebCacheManager::GetInstance();
  int requested = 0;
  for (auto hosts = content::RenderProcessHost::AllHostsIterator();
       !hosts.IsAtEnd(); hosts.Advance()) {
    auto* process = hosts.GetCurrentValue();
    auto* candidate = process->GetBrowserContext();
    if (!candidate || candidate->ShutdownStarted()) {
      continue;
    }
    bool matches = candidate == owner;
    if (!matches && profile && !profile->IsOffTheRecord()) {
      // Parent control/list changes also affect its OTR children, but never
      // another normal Profile or the parent's normal context from an OTR.
      auto* child = CefBrowserContext::FromBrowserContext(candidate);
      auto* child_profile = child ? child->AsProfile() : nullptr;
      matches = child_profile && child_profile->IsOffTheRecord() &&
                child_profile->GetOriginalProfile() == profile;
    }
    if (matches && cache->ClearCacheForProcessOnNavigation(process->GetID())) {
      ++requested;
    }
  }
  return requested;
}

open_engine::OpenAdBlockService* ServiceFor(
    CefRefPtr<CefRequestContext> request_context) {
  if (!request_context) {
    return nullptr;
  }
  // Never use GetOrCreateForRequestContext: null must not select Default.
  // The initialized accessor also rejects a retained, detached OTR wrapper.
  auto* context = static_cast<CefRequestContextImpl*>(request_context.get())
                      ->GetInitializedBrowserContext();
  if (!context || context->AsBrowserContext()->ShutdownStarted()) {
    return nullptr;
  }
  return context->open_adblock_service();
}

void RefreshFactoriesFor(CefRefPtr<CefRequestContext> request_context) {
  auto* context = static_cast<CefRequestContextImpl*>(request_context.get())
                      ->GetInitializedBrowserContext();
  if (!context) return;
  // Disabled/excluded documents have no proxy (§7.2). Rebuild their existing
  // factories when control state changes, as Chromium's WebRequestAPI does
  // on proxy transitions; otherwise enabling would wait for navigation.
  // Only touch loaded partitions, and only in this context (including OTR).
  context->AsBrowserContext()->ForEachLoadedStoragePartition(
      [](content::StoragePartition* partition) {
        partition->ResetURLLoaderFactories();
      });
}

}  // namespace

namespace open_engine {

void ConfigureAdBlockRendererCache(CefBrowserContext* context,
                                  OpenAdBlockService* service) {
  CEF_REQUIRE_UIT();
  service->SetRendererCacheInvalidator(base::BindRepeating(
      &ClearRendererCachesOnNavigation, context->getter()));
}

}  // namespace open_engine

bool CefSetOpenAdBlockEnabled(CefRefPtr<CefRequestContext> request_context,
                               bool enabled) {
  CEF_REQUIRE_UIT_RETURN(false);
  auto* service = ServiceFor(request_context);
  if (!service) return false;
  if (service->IsEnabled() == enabled) return true;
  service->SetEnabled(enabled);
  RefreshFactoriesFor(request_context);
  return true;
}

bool CefSetOpenAdBlockListDirectory(
    CefRefPtr<CefRequestContext> request_context, const CefString& list_dir) {
  CEF_REQUIRE_UIT_RETURN(false);
  auto* service = ServiceFor(request_context);
  if (!service) return false;
  service->SetListDirectory(base::FilePath(list_dir.ToString()));
  return true;
}

bool CefReloadOpenAdBlockLists(CefRefPtr<CefRequestContext> request_context) {
  CEF_REQUIRE_UIT_RETURN(false);
  auto* service = ServiceFor(request_context);
  if (!service) return false;
  service->ReloadLists();
  return true;
}

bool CefSetOpenAdBlockExcludedDomains(
    CefRefPtr<CefRequestContext> request_context,
    const std::vector<CefString>& domains) {
  CEF_REQUIRE_UIT_RETURN(false);
  auto* service = ServiceFor(request_context);
  if (!service) return false;
  std::vector<std::string> values;
  values.reserve(domains.size());
  for (const auto& domain : domains) values.push_back(domain.ToString());
  const auto previous = service->GetStatus().excluded_domains;
  service->SetExcludedDomains(std::move(values));
  // A status observer may close the context inside the setter.
  auto* current = ServiceFor(request_context);
  if (current && previous != current->GetStatus().excluded_domains) {
    RefreshFactoriesFor(request_context);
  }
  return true;
}

CefRefPtr<CefDictionaryValue> CefGetOpenAdBlockStatus(
    CefRefPtr<CefRequestContext> request_context) {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  auto* service = ServiceFor(request_context);
  if (!service) return nullptr;
  const auto status = service->GetStatus();
  auto value = CefDictionaryValue::Create();
  value->SetBool("enabled", status.enabled);
  value->SetBool("engine_loaded", status.engine_loaded);
  value->SetBool("awaiting_generation", status.awaiting_generation);
  value->SetBool("engine_from_dat", status.engine_from_dat);
  value->SetBool("engine_shared", status.engine_shared);
  value->SetString("dat_policy", status.dat_policy);
  value->SetInt("list_count", status.list_count);
  value->SetInt("resources_loaded", status.resources_loaded);
  value->SetDouble("last_build_ms", status.last_build_ms);
  // Service errors contain only fixed operation text and input basenames;
  // expose a fixed summary so even a hostile manifest name cannot leak a path.
  value->SetString("last_error", status.last_error.empty()
                                     ? "" : "Ad-block list load or cache failed");
  value->SetInt("excluded_count", status.excluded_domains.size());
  // Generation IDs are int64, beyond CefDictionaryValue's 32-bit integer.
  value->SetDouble("load_generation", status.generation);
  value->SetDouble("cold_holds", status.cold_holds);
  value->SetDouble("cold_hold_max_ms", status.cold_hold_max_ms);
  return value;
}

int CefGetOpenAdBlockBlockedCount(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UIT_RETURN(0);
  auto host = CefBrowserHostBase::FromBrowser(browser);
  auto* contents = host ? host->GetWebContents() : nullptr;
  auto* helper = contents
      ? open_engine::OpenAdBlockTabHelper::FromWebContents(contents) : nullptr;
  return helper ? helper->total_count() : 0;
}
