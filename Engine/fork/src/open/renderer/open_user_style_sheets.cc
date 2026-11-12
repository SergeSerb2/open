// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/renderer/open_user_style_sheets.h"

#include <map>
#include <string>

#include "base/logging.h"
#include "base/no_destructor.h"
#include "cef/include/cef_open_page.h"
#include "cef/libcef/renderer/browser_impl.h"
#include "third_party/blink/public/platform/web_string.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/web_frame.h"
#include "third_party/blink/public/web/web_local_frame.h"
#include "third_party/blink/public/web/web_view.h"

namespace open_engine {

namespace {

// browser id → (key → CSS). Renderer main thread only.
using Sheets = std::map<std::string, std::string>;
std::map<int, Sheets>& AllSheets() {
  static base::NoDestructor<std::map<int, Sheets>> sheets;
  return *sheets;
}

blink::WebString SheetKey(const std::string& key) {
  return blink::WebString::FromUtf8("open-user-style-sheet:" + key);
}

// StyleEngine::RemoveInjectedSheet removes only the last sheet with the key.
// A document can receive the same key more than once (the commit hook and a
// live update can race at document creation), so clear every copy. A few
// passes are enough: each insert below starts from none.
void RemoveAll(blink::WebDocument document, const std::string& key) {
  const blink::WebString sheet_key = SheetKey(key);
  for (int i = 0; i < 4; ++i) {
    document.RemoveInsertedStyleSheet(sheet_key, blink::WebCssOrigin::kUser);
  }
}

void Insert(blink::WebDocument document,
            const std::string& key,
            const std::string& css) {
  RemoveAll(document, key);
  const blink::WebString sheet_key = SheetKey(key);
  document.InsertStyleSheet(blink::WebString::FromUtf8(css), &sheet_key,
                            blink::WebCssOrigin::kUser);
}

}  // namespace

void ApplyUserStyleSheetsAtCommit(blink::WebLocalFrame* frame, int browser_id) {
  if (!frame) {
    return;
  }
  auto it = AllSheets().find(browser_id);
  if (it == AllSheets().end()) {
    return;
  }
  blink::WebDocument document = frame->GetDocument();
  if (document.IsNull()) {
    return;
  }
  for (const auto& [key, css] : it->second) {
    Insert(document, key, css);
  }
}

}  // namespace open_engine

bool CefSetOpenUserStyleSheet(CefRefPtr<CefBrowser> browser,
                              const CefString& key,
                              const CefString& css) {
  if (!browser) {
    return false;
  }
  const std::string sheet = key.ToString();
  const std::string source = css.ToString();
  open_engine::Sheets& sheets =
      open_engine::AllSheets()[browser->GetIdentifier()];
  const bool had = sheets.count(sheet) > 0;
  if (source.empty()) {
    sheets.erase(sheet);
  } else {
    sheets[sheet] = source;
  }
  // Apply to the current main-frame document when it is in this process.
  auto* impl = static_cast<CefBrowserImpl*>(browser.get());
  blink::WebLocalFrame* frame =
      impl && impl->GetWebView() && impl->GetWebView()->MainFrame() &&
              impl->GetWebView()->MainFrame()->IsWebLocalFrame()
          ? impl->GetWebView()->MainFrame()->ToWebLocalFrame()
          : nullptr;
  LOG(WARNING) << "E3DBG uss set browser=" << browser->GetIdentifier()
               << " key=" << sheet << " bytes=" << source.size()
               << " had=" << had << " frame=" << !!frame;
  if (!frame || frame->GetDocument().IsNull()) {
    return true;
  }
  blink::WebDocument document = frame->GetDocument();
  if (had || source.empty()) {
    open_engine::RemoveAll(document, sheet);
  }
  if (!source.empty()) {
    open_engine::Insert(document, sheet, source);
  }
  return true;
}

void CefForgetOpenUserStyleSheets(CefRefPtr<CefBrowser> browser) {
  if (browser) {
    open_engine::AllSheets().erase(browser->GetIdentifier());
  }
}
