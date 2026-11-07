// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#ifndef OPEN_BROWSER_AUTOFILL_OPEN_SAVE_PROMPT_IMPL_H_
#define OPEN_BROWSER_AUTOFILL_OPEN_SAVE_PROMPT_IMPL_H_

#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "cef/include/cef_open_autofill.h"
#include "content/public/browser/web_contents_observer.h"

namespace open_engine {
class OpenSavePrompt final : public CefSavePrompt,
                             public content::WebContentsObserver {
 public:
  OpenSavePrompt(content::WebContents* contents, int kind, bool user_initiated,
                 base::OnceCallback<void(int)> answer);
  bool IsSame(CefRefPtr<CefSavePrompt> that) override;
  int GetKind() override;
  CefString GetOrigin() override;
  CefString GetDisplayHost() override;
  CefString GetUsername() override;
  CefString GetCardLabel() override;
  CefString GetAddressLabel() override;
  bool IsUserInitiated() override;
  bool IsAnswered() override;
  void Answer(int answer) override;
  void Withdraw();
  void DidFinishNavigation(content::NavigationHandle* navigation) override;
  void WebContentsDestroyed() override;
  base::WeakPtr<OpenSavePrompt> GetWeakPtr();
  void SetLabels(std::u16string username, std::u16string card,
                 std::u16string address);

 private:
  ~OpenSavePrompt() override;
  int kind_;
  bool user_initiated_;
  std::string origin_;
  std::u16string host_, username_, card_, address_;
  base::OnceCallback<void(int)> answer_;
  base::WeakPtrFactory<OpenSavePrompt> weak_factory_{this};
  IMPLEMENT_REFCOUNTING(OpenSavePrompt);
};
}  // namespace open_engine
#endif
