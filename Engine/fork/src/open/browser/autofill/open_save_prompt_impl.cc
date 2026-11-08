// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#include "open/browser/autofill/open_save_prompt_impl.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "components/url_formatter/elide_url.h"
#include "content/public/browser/web_contents.h"
#include "open/browser/autofill/open_autofill_handler_registry.h"
#include "url/origin.h"

namespace open_engine {
OpenSavePrompt::OpenSavePrompt(content::WebContents* contents, int kind,
    bool user_initiated, base::OnceCallback<void(int)> answer)
    : WebContentsObserver(contents), kind_(kind),
      user_initiated_(user_initiated), answer_(std::move(answer)) {
  const auto origin = url::Origin::Create(contents->GetLastCommittedURL());
  origin_ = origin.Serialize();
  host_ = url_formatter::FormatOriginForSecurityDisplay(
      origin, url_formatter::SchemeDisplay::OMIT_HTTP_AND_HTTPS);
}
OpenSavePrompt::~OpenSavePrompt() {
  ForgetSavePrompt(web_contents(), this);
  if (answer_) std::move(answer_).Run(3);
}
bool OpenSavePrompt::IsSame(CefRefPtr<CefSavePrompt> that) { return this == that.get(); }
int OpenSavePrompt::GetKind() { return kind_; }
CefString OpenSavePrompt::GetOrigin() { return origin_; }
CefString OpenSavePrompt::GetDisplayHost() { return host_; }
CefString OpenSavePrompt::GetUsername() { return username_; }
CefString OpenSavePrompt::GetCardLabel() { return card_; }
CefString OpenSavePrompt::GetAddressLabel() { return address_; }
bool OpenSavePrompt::IsUserInitiated() { return user_initiated_; }
bool OpenSavePrompt::IsAnswered() { return !answer_; }
base::WeakPtr<OpenSavePrompt> OpenSavePrompt::GetWeakPtr() {
  return weak_factory_.GetWeakPtr();
}
void OpenSavePrompt::SetLabels(std::u16string username, std::u16string card,
                               std::u16string address) {
  username_ = std::move(username);
  card_ = std::move(card);
  address_ = std::move(address);
}
void OpenSavePrompt::Answer(int answer) {
  if (!answer_) return;
  CefRefPtr<OpenSavePrompt> keep_alive(this);
  ForgetSavePrompt(web_contents(), this);
  auto callback = std::move(answer_);
  std::move(callback).Run(answer >= 0 && answer <= 3 ? answer : 3);
}
void OpenSavePrompt::Withdraw() {
  if (IsAnswered()) return;
  CefRefPtr<OpenSavePrompt> keep_alive(this);
  auto browser = CefBrowserHostBase::GetBrowserForContents(web_contents());
  Answer(3);
  NotifyPromptWithdrawn(browser, this);
}
// Navigation alone does not withdraw an offer. Chromium keeps pending state
// while its bubble is open; its own hide routes settle the corresponding offer.
void OpenSavePrompt::WebContentsDestroyed() {
  Withdraw();
  Observe(nullptr);
}
}  // namespace open_engine
