// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#include "open/browser/autofill/open_autofill_handler_registry.h"

#include <map>
#include <vector>
#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/thread_util.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/web_contents.h"
#include "open/browser/autofill/open_autofill_hooks.h"
#include "open/browser/autofill/open_password_prompt_router.h"
#include "open/browser/autofill/open_save_prompt_impl.h"
#include "components/autofill/content/browser/content_autofill_client.h"

namespace open_engine {
namespace {
struct Registry {
  CefRefPtr<CefOpenAutofillHandler> handler;
  // Weak: releasing the shell's unanswered prompt must ignore it.
  std::map<content::WebContents*, base::WeakPtr<OpenSavePrompt>> prompts;
};
Registry& State() { static base::NoDestructor<Registry> state; return *state; }
}  // namespace

bool IsOpenWebContents(content::WebContents* contents) {
  if (!contents || !State().handler) return false;
  auto browser = CefBrowserHostBase::GetBrowserForContents(contents);
  return browser && State().handler->IsOpenBrowser(browser);
}
bool SecretsPromptsAllowed(content::WebContents* contents) {
  if (!contents || contents->GetBrowserContext()->IsOffTheRecord()) return false;
  auto* cmd = base::CommandLine::ForCurrentProcess();
  return !cmd->HasSwitch("use-mock-keychain") ||
         cmd->HasSwitch("open-allow-mock-keychain-secrets");
}
bool OpenAutofillPage(content::WebContents* contents, int page) {
  if (!IsOpenWebContents(contents)) return false;
  auto handler = State().handler;
  handler->OnOpenAutofillPage(
      CefBrowserHostBase::GetBrowserForContents(contents), page);
  return true;
}
void NotifyPasswordSaveKeychainError(content::WebContents* contents) {
  if (!IsOpenWebContents(contents)) return;
  auto handler = State().handler;
  handler->OnPasswordSaveKeychainError(
      CefBrowserHostBase::GetBrowserForContents(contents));
}
void ForgetSavePrompt(content::WebContents* contents, OpenSavePrompt* prompt) {
  auto found = State().prompts.find(contents);
  if (found != State().prompts.end() && found->second.get() == prompt)
    State().prompts.erase(found);
}
void NotifyPromptWithdrawn(CefRefPtr<CefBrowser> browser, OpenSavePrompt* prompt) {
  // A shell delegate may close its page. Deliver outside the controller's
  // Hide/close stack, just like the initial offer.
  if (!browser) return;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
      base::BindOnce([](CefRefPtr<CefBrowser> browser, CefRefPtr<OpenSavePrompt> prompt) {
        auto handler = State().handler;
        if (handler) handler->OnWithdrawSavePrompt(browser, prompt);
      }, browser, CefRefPtr<OpenSavePrompt>(prompt)));
}
void WithdrawSavePrompt(content::WebContents* contents) {
  auto found = State().prompts.find(contents);
  if (found != State().prompts.end() && found->second) found->second->Withdraw();
}
void WithdrawPasswordSavePrompt(content::WebContents* contents) {
  auto found = State().prompts.find(contents);
  // Password UI state changes also run after address/payment submissions.
  // Only that UI's own offers belong to its show/hide lifecycle.
  if (found != State().prompts.end() && found->second &&
      found->second->GetKind() <= 1) {
    found->second->Withdraw();
  }
}
void ShowSavePrompt(CefRefPtr<OpenSavePrompt> prompt) {
  auto* contents = prompt->web_contents();
  WithdrawSavePrompt(contents);
  if (prompt->IsAnswered() || !prompt->web_contents()) return;
  State().prompts[contents] = prompt->GetWeakPtr();
  // Controllers first install their non-null bubble view. Even an ignored
  // prompt closes on a later turn, to avoid reentering DoShowBubble().
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce([](CefRefPtr<OpenSavePrompt> prompt) {
        auto* contents = prompt->web_contents();
        if (prompt->IsAnswered()) return;
        if (!IsOpenWebContents(contents) ||
            contents->GetBrowserContext()->IsOffTheRecord() ||
            (prompt->GetKind() <= 2 && !SecretsPromptsAllowed(contents))) {
          prompt->Answer(3);
          return;
        }
        if (prompt->GetKind() == 2) {
          // Chromium gates filling on this predicate, but local card saving
          // does not. Apply the same HTTPS/security-level rule to Open offers.
          auto* client = autofill::ContentAutofillClient::FromWebContents(contents);
          if (!client || !client->IsContextSecure()) {
            prompt->Answer(3);
            return;
          }
        }
        auto handler = State().handler;
        handler->OnShowSavePrompt(
            CefBrowserHostBase::GetBrowserForContents(contents), prompt);
      }, prompt));
}
}  // namespace open_engine

void CefSetOpenAutofillHandler(CefRefPtr<CefOpenAutofillHandler> handler) {
  CEF_REQUIRE_UIT();
  auto& state = open_engine::State();
  std::vector<base::WeakPtr<open_engine::OpenSavePrompt>> pending;
  for (const auto& [contents, prompt] : state.prompts) pending.push_back(prompt);
  for (auto prompt : pending) if (prompt) prompt->Withdraw();
  state.prompts.clear();
  state.handler = handler;
  auto& hooks = open_engine::GetAutofillHooks();
  hooks.is_open = open_engine::IsOpenWebContents;
  hooks.show_password = open_engine::OpenPasswordPromptRouter::Show;
  hooks.hide_password = open_engine::OpenPasswordPromptRouter::Hide;
  hooks.open_page = open_engine::OpenAutofillPage;
  open_engine::InstallNullCredentialDialogHooks();
}
