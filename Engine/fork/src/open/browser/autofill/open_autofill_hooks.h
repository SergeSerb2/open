// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#ifndef OPEN_BROWSER_AUTOFILL_OPEN_AUTOFILL_HOOKS_H_
#define OPEN_BROWSER_AUTOFILL_OPEN_AUTOFILL_HOOKS_H_

#include "chrome/browser/ui/passwords/password_dialog_prompts.h"
#include "components/autofill/core/browser/ui/payments/autofill_error_dialog_view.h"
#include "components/autofill/core/browser/ui/payments/card_unmask_prompt_view.h"

namespace autofill {
class AutofillErrorDialogController;
class CardUnmaskPromptController;
}
namespace open_engine {
// Chromium targets cannot link to libcef. The overlay installs these hooks.
// A missing hook preserves Chromium's normal behavior.
struct AutofillHooks {
  bool (*is_open)(content::WebContents*) = nullptr;
  bool (*show_password)(content::WebContents*, bool) = nullptr;
  bool (*hide_password)(content::WebContents*) = nullptr;
  bool (*open_page)(content::WebContents*, int) = nullptr;
  std::unique_ptr<AccountChooserPrompt> (*account)(
      CredentialManagerDialogController*) = nullptr;
  std::unique_ptr<AutoSigninFirstRunPrompt> (*autosignin)(
      CredentialManagerDialogController*) = nullptr;
  std::unique_ptr<CredentialLeakPrompt> (*leak)(
      CredentialLeakDialogController*) = nullptr;
  autofill::CardUnmaskPromptView* (*unmask)(
      autofill::CardUnmaskPromptController*) = nullptr;
  base::WeakPtr<autofill::AutofillErrorDialogView> (*error)(
      autofill::AutofillErrorDialogController*) = nullptr;
};
inline AutofillHooks& GetAutofillHooks() {
  static AutofillHooks hooks;
  return hooks;
}
}  // namespace open_engine
#endif
