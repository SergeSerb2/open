// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Website appearance (docs/plans/page-platform.md §4.8, EP-9b). Chrome's own
// rule (GetPreferredColorScheme in chrome_content_browser_client.cc) takes the
// scheme from the page's color provider, which hosted Open tabs do not get
// from CefRequestContext::SetChromeColorScheme (check A1). This override is
// per browser context and wins over Chrome's value.

#include "open/browser/page/open_website_color_scheme.h"

#include <memory>

#include "base/functional/bind.h"
#include "base/supports_user_data.h"
#include "cef/include/cef_open_page.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/browser_info.h"
#include "cef/libcef/browser/browser_info_manager.h"
#include "cef/libcef/browser/request_context_impl.h"
#include "cef/libcef/browser/thread_util.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/web_contents.h"
#include "third_party/blink/public/common/web_preferences/web_preferences.h"
#include "third_party/blink/public/mojom/css/preferred_color_scheme.mojom-shared.h"
#include "url/gurl.h"

namespace open_engine {

namespace {

const char kWebsiteColorSchemeKey[] = "open_engine.website_color_scheme";

// The forced scheme of one browser context; absent means no override.
struct WebsiteColorScheme : public base::SupportsUserData::Data {
  explicit WebsiteColorScheme(blink::mojom::PreferredColorScheme scheme)
      : scheme(scheme) {}
  blink::mojom::PreferredColorScheme scheme;
};

const WebsiteColorScheme* SchemeFor(content::BrowserContext* context) {
  return context ? static_cast<const WebsiteColorScheme*>(
                       context->GetUserData(kWebsiteColorSchemeKey))
                 : nullptr;
}

// DevTools and Chrome's own pages keep the browser's scheme.
bool IsWebsite(content::WebContents* web_contents) {
  const GURL& url = web_contents->GetLastCommittedURL();
  return !url.SchemeIs("devtools") && !url.SchemeIs("chrome") &&
         !url.SchemeIs("chrome-untrusted");
}

void Apply(CefRefPtr<CefRequestContextImpl> request_context,
           cef_color_variant_t variant) {
  CefBrowserContext* cef_context = request_context->GetBrowserContext();
  if (!cef_context) {
    return;
  }
  content::BrowserContext* context = cef_context->AsBrowserContext();
  if (variant == CEF_COLOR_VARIANT_LIGHT || variant == CEF_COLOR_VARIANT_DARK) {
    context->SetUserData(
        kWebsiteColorSchemeKey,
        std::make_unique<WebsiteColorScheme>(
            variant == CEF_COLOR_VARIANT_DARK
                ? blink::mojom::PreferredColorScheme::kDark
                : blink::mojom::PreferredColorScheme::kLight));
  } else {
    context->RemoveUserData(kWebsiteColorSchemeKey);
  }
  // Recompute the preferences of every live page of this context (all CEF
  // browsers, hosted tabs included); OverrideWebPreferences applies the new
  // value, or Chrome's own after a removal.
  for (const auto& info :
       CefBrowserInfoManager::GetInstance()->GetBrowserInfoList()) {
    CefRefPtr<CefBrowserHostBase> browser = info->browser();
    content::WebContents* web_contents =
        browser ? browser->GetWebContents() : nullptr;
    if (web_contents && web_contents->GetBrowserContext() == context) {
      web_contents->NotifyPreferencesChanged();
    }
  }
}

}  // namespace

bool ApplyWebsiteColorScheme(content::WebContents* web_contents,
                             blink::web_pref::WebPreferences* prefs) {
  if (!web_contents || !prefs || !IsWebsite(web_contents)) {
    return false;
  }
  const WebsiteColorScheme* forced =
      SchemeFor(web_contents->GetBrowserContext());
  if (!forced) {
    return false;
  }
  bool changed = prefs->preferred_color_scheme != forced->scheme ||
                 prefs->preferred_root_scrollbar_color_scheme != forced->scheme;
  prefs->preferred_color_scheme = forced->scheme;
  prefs->preferred_root_scrollbar_color_scheme = forced->scheme;
  return changed;
}

}  // namespace open_engine

bool CefSetWebsiteColorScheme(CefRefPtr<CefRequestContext> request_context,
                              cef_color_variant_t variant) {
  CEF_REQUIRE_UIT_RETURN(false);
  CefRefPtr<CefRequestContextImpl> impl =
      static_cast<CefRequestContextImpl*>(request_context.get());
  if (!impl) {
    return false;
  }
  impl->ExecuteWhenBrowserContextInitialized(
      base::BindOnce(&open_engine::Apply, impl, variant));
  return true;
}
