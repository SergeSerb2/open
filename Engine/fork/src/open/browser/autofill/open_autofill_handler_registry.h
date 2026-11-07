// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#ifndef OPEN_BROWSER_AUTOFILL_OPEN_AUTOFILL_HANDLER_REGISTRY_H_
#define OPEN_BROWSER_AUTOFILL_OPEN_AUTOFILL_HANDLER_REGISTRY_H_
#include "cef/include/cef_open_autofill.h"
namespace content { class WebContents; }
namespace open_engine {
class OpenSavePrompt;
bool IsOpenWebContents(content::WebContents* contents);
bool SecretsPromptsAllowed(content::WebContents* contents);
bool OpenAutofillPage(content::WebContents* contents, int page);
void NotifyPasswordSaveKeychainError(content::WebContents* contents);
void ShowSavePrompt(CefRefPtr<OpenSavePrompt> prompt);
void WithdrawSavePrompt(content::WebContents* contents);
void NotifyPromptWithdrawn(CefRefPtr<CefBrowser> browser, OpenSavePrompt* prompt);
void ForgetSavePrompt(content::WebContents* contents, OpenSavePrompt* prompt);
void InstallNullCredentialDialogHooks();
}  // namespace open_engine
#endif
