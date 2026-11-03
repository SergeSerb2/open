// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_PAGE_OPEN_WEBSITE_COLOR_SCHEME_H_
#define OPEN_BROWSER_PAGE_OPEN_WEBSITE_COLOR_SCHEME_H_

namespace blink::web_pref {
struct WebPreferences;
}
namespace content {
class WebContents;
}

namespace open_engine {

// Applies the website color scheme of |web_contents|' browser context
// (CefSetWebsiteColorScheme, page-platform EP-9b) to |prefs|. Called by
// ChromeContentBrowserClientCef after Chrome computed its own scheme, on
// creation and after every navigation (patch 0505). Returns true if it
// changed |prefs|.
bool ApplyWebsiteColorScheme(content::WebContents* web_contents,
                             blink::web_pref::WebPreferences* prefs);

}  // namespace open_engine

#endif  // OPEN_BROWSER_PAGE_OPEN_WEBSITE_COLOR_SCHEME_H_
