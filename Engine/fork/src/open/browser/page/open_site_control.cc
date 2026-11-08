// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "cef/include/cef_site_control.h"

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/time/time.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/browser_context.h"
#include "cef/libcef/browser/request_context_impl.h"
#include "cef/libcef/browser/thread_util.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "components/content_settings/core/browser/content_settings_registry.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings_pattern.h"
#include "chrome/browser/ssl/chrome_security_state_util.h"
#include "components/security_state/core/security_state.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browsing_data_filter_builder.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "net/cookies/canonical_cookie.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace {

GURL SiteOrigin(const CefString& value) {
  if (value.length() > 16384) return GURL();
  const auto text = value.ToString();
  if (text.find('\0') != std::string::npos) return GURL();
  const GURL url(text);
  const auto origin = url::Origin::Create(url);
  return url.SchemeIsHTTPOrHTTPS() && !origin.opaque() ? origin.GetURL() : GURL();
}

HostContentSettingsMap* Settings(CefRefPtr<CefRequestContext> context) {
  if (!context) return nullptr;
  auto* impl = static_cast<CefRequestContextImpl*>(context.get());
  return impl->VerifyBrowserContext()
      ? HostContentSettingsMapFactory::GetForProfile(impl->GetBrowserContext()->AsBrowserContext())
      : nullptr;
}

const char* StateName(ContentSetting state) {
  switch (state) {
    case CONTENT_SETTING_ALLOW: return "allow";
    case CONTENT_SETTING_BLOCK: return "block";
    case CONTENT_SETTING_ASK: return "ask";
    case CONTENT_SETTING_SESSION_ONLY: return "session";
    default: return nullptr;
  }
}

// Self-owned until the remover and every cookie callback finish. Each callback
// can close the profile; no observer or iterator survives user completion.
class SiteDataRemoval : public content::BrowsingDataRemover::Observer {
 public:
  SiteDataRemoval(CefRefPtr<CefRequestContextImpl> context,
                  GURL origin, int types, CefRefPtr<CefSiteDataCallback> callback)
      : context_(context), origin_(std::move(origin)), types_(types), callback_(callback) {}

  void Start() {
    auto* context = context_->GetBrowserContext()->AsBrowserContext();
    uint64_t mask = 0;
    if (types_ & 2) mask |= content::BrowsingDataRemover::DATA_TYPE_CACHE;
    if (types_ & 4) mask |= content::BrowsingDataRemover::DATA_TYPE_DOM_STORAGE |
        content::BrowsingDataRemover::DATA_TYPE_SHARED_STORAGE;
    if (mask) {
      auto filter = content::BrowsingDataFilterBuilder::Create(
          content::BrowsingDataFilterBuilder::Mode::kDelete,
          content::BrowsingDataFilterBuilder::OriginMatchingMode::kOriginInAllContexts);
      filter->AddOrigin(url::Origin::Create(origin_));
      remover_ = context->GetBrowsingDataRemover();
      remover_->AddObserver(this);
      ++pending_;
      remover_->RemoveWithFilterAndReply(base::Time(), base::Time::Max(), mask,
          content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB |
          content::BrowsingDataRemover::ORIGIN_TYPE_PROTECTED_WEB,
          std::move(filter), this);
    }
    if (types_ & 1) {
      ++pending_;
      // BrowsingDataFilterBuilder forbids AddOrigin for cookies, and its
      // eTLD+1 filter would erase unrelated sibling hosts. Canonical deletion
      // matches the host/domain across every cookie path and partition.
      context->GetDefaultStoragePartition()->GetCookieManagerForBrowserProcess()
          ->GetAllCookies(mojo::WrapCallbackWithDropHandler(
              base::BindOnce(&SiteDataRemoval::Cookies, base::Unretained(this)),
              base::BindOnce(&SiteDataRemoval::Done, base::Unretained(this), false)));
    }
    Done(true);  // Release the start sentinel, also for an empty selection.
  }

  void OnBrowsingDataRemoverDone(uint64_t failed) override {
    remover_->RemoveObserver(this);
    remover_ = nullptr;
    Done(failed == 0);
  }

 private:
  void Cookies(const net::CookieList& cookies) {
    // Chrome normally bounds its store to ~3300 cookies. Refuse an abnormal
    // result before queuing deletes. Worst accepted string storage is 64 MiB;
    // one canonical-cookie allocation remains bounded by Chrome's cookie limit.
    size_t bytes = 0;
    for (const auto& cookie : cookies) {
      bytes += cookie.Name().size() + cookie.Value().size() +
               cookie.Domain().size() + cookie.Path().size();
    }
    if (cookies.size() > 10000 || bytes > 64 * 1024 * 1024) {
      Done(false);
      return;
    }
    auto* manager = context_->GetBrowserContext()->AsBrowserContext()
        ->GetDefaultStoragePartition()->GetCookieManagerForBrowserProcess();
    for (const auto& cookie : cookies) {
      if (!cookie.IsDomainMatch(origin_.host())) continue;
      ++pending_;
      manager->DeleteCanonicalCookie(cookie, mojo::WrapCallbackWithDropHandler(
          base::BindOnce(&SiteDataRemoval::Done, base::Unretained(this)),
          base::BindOnce(&SiteDataRemoval::Done, base::Unretained(this), false)));
    }
    Done(true);  // Enumeration stays live until all deletes have been queued.
  }

  void Done(bool success) {
    success_ &= success;
    if (--pending_) return;
    auto context = context_;
    auto callback = callback_;
    const bool result = success_;
    delete this;
    callback->OnComplete(result);
  }

  CefRefPtr<CefRequestContextImpl> context_;
  GURL origin_;
  int types_;
  CefRefPtr<CefSiteDataCallback> callback_;
  raw_ptr<content::BrowsingDataRemover> remover_ = nullptr;
  size_t pending_ = 1;
  bool success_ = true;
};
}  // namespace

CefRefPtr<CefListValue> CefGetChangedSiteSettings(
    CefRefPtr<CefRequestContext> context, const CefString& origin) {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  auto list = CefListValue::Create();
  const auto url = SiteOrigin(origin);
  auto* settings = Settings(context);
  if (!settings || !url.is_valid()) return list;
  for (const auto* item : *content_settings::ContentSettingsRegistry::GetInstance()) {
    const auto* info = item->website_settings_info();
    content_settings::SettingInfo rule;
    const auto state = settings->GetContentSetting(url, url, info->type(), &rule);
    const char* name = StateName(state);
    if (!name || state == settings->GetDefaultContentSetting(info->type(), nullptr) ||
        (rule.primary_pattern == ContentSettingsPattern::Wildcard() &&
         rule.secondary_pattern == ContentSettingsPattern::Wildcard())) continue;
    auto value = CefDictionaryValue::Create();
    value->SetString("kind", info->name());
    value->SetString("state", name);
    list->SetDictionary(list->GetSize(), value);
  }
  return list;
}

bool CefSetSiteSetting(CefRefPtr<CefRequestContext> context,
                       const CefString& origin, const CefString& kind,
                       const CefString& value) {
  CEF_REQUIRE_UIT_RETURN(false);
  const auto url = SiteOrigin(origin);
  auto* settings = Settings(context);
  if (!settings || !url.is_valid() || kind.length() > 128 || value.length() > 16)
    return false;
  const auto name = kind.ToString(), state = value.ToString();
  ContentSetting setting = CONTENT_SETTING_DEFAULT;
  if (state == "allow") setting = CONTENT_SETTING_ALLOW;
  else if (state == "block") setting = CONTENT_SETTING_BLOCK;
  else if (state == "ask") setting = CONTENT_SETTING_ASK;
  else if (state == "session") setting = CONTENT_SETTING_SESSION_ONLY;
  else return false;
  for (const auto* item : *content_settings::ContentSettingsRegistry::GetInstance()) {
    if (item->website_settings_info()->name() != name) continue;
    if (!item->IsSettingValid(setting)) return false;
    settings->SetContentSettingDefaultScope(url, url,
        item->website_settings_info()->type(), setting);
    return true;
  }
  return false;
}

bool CefClearSiteData(CefRefPtr<CefRequestContext> context,
                      const CefString& origin, int types,
                      CefRefPtr<CefSiteDataCallback> callback) {
  CEF_REQUIRE_UIT_RETURN(false);
  const auto url = SiteOrigin(origin);
  if (!context || !callback || !url.is_valid() || (types & ~7) || types < 0)
    return false;
  CefRefPtr<CefRequestContextImpl> impl = static_cast<CefRequestContextImpl*>(context.get());
  impl->ExecuteWhenBrowserContextInitialized(base::BindOnce(
      [](CefRefPtr<CefRequestContextImpl> impl, GURL url, int types,
         CefRefPtr<CefSiteDataCallback> callback) {
        (new SiteDataRemoval(impl, std::move(url), types, callback))->Start();
      }, impl, url, types, callback));
  return true;
}

CefString CefGetSiteSecurityLevel(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UIT_RETURN(CefString("neutral"));
  auto host = CefBrowserHostBase::FromBrowser(browser);
  auto* contents = host ? host->GetWebContents() : nullptr;
  if (!contents) return "neutral";
  auto state = chrome_security_state::GetVisibleSecurityState(contents);
  if (security_state::HasMajorCertificateError(*state) ||
      state->malicious_content_status != security_state::MALICIOUS_CONTENT_STATUS_NONE)
    return "dangerous";
  if (state->displayed_mixed_content || state->ran_mixed_content ||
      state->displayed_content_with_cert_errors || state->ran_content_with_cert_errors)
    return "mixedContent";
  switch (security_state::GetSecurityLevel(*state)) {
    case security_state::SECURE: return "secure";
    case security_state::DANGEROUS: return "dangerous";
    case security_state::WARNING: return "insecure";
    default: return state->url.SchemeIs("http") ? "insecure" : "neutral";
  }
}
