// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#include "open/browser/autofill/open_password_prompt_router.h"
#include "base/functional/bind.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/passwords/bubble_controllers/save_update_bubble_controller.h"
#include "chrome/browser/ui/passwords/passwords_model_delegate.h"
#include "components/password_manager/core/browser/password_form.h"
#include "content/public/browser/web_contents.h"
#include "open/browser/autofill/open_autofill_handler_registry.h"
#include "open/browser/autofill/open_save_prompt_impl.h"

namespace open_engine {
bool OpenPasswordPromptRouter::Show(content::WebContents* contents,
                                    bool user_action) {
  if (!IsOpenWebContents(contents)) return false;
  auto live_contents = contents->GetWeakPtr();
  WithdrawSavePrompt(contents);
  if (!live_contents) return true;
  auto delegate = PasswordsModelDelegateFromWebContents(contents);
  if (!delegate) return true;
  const auto state = delegate->GetState();
  if (state != password_manager::ui::PENDING_PASSWORD_STATE &&
      state != password_manager::ui::PENDING_PASSWORD_UPDATE_STATE) {
    if (state == password_manager::ui::KEYCHAIN_ERROR_STATE)
      NotifyPasswordSaveKeychainError(contents);
    if (!delegate) return true;
    delegate->OnBubbleShown();
    if (delegate) delegate->OnBubbleHidden();
    if (state == password_manager::ui::MANAGE_STATE && user_action && live_contents)
      OpenAutofillPage(live_contents.get(), 0);
    return true;
  }
  auto controller = std::make_unique<SaveUpdateBubbleController>(
      delegate, user_action ? PasswordBubbleControllerBase::DisplayReason::kUserAction
                            : PasswordBubbleControllerBase::DisplayReason::kAutomatic);
  const auto username = delegate->GetPendingPassword().username_value;
  auto answer = base::BindOnce(
      [](std::unique_ptr<SaveUpdateBubbleController> controller,
         base::WeakPtr<PasswordsModelDelegate> delegate,
         password_manager::ui::State state, int choice) {
        // The bubble controller caches its initial state. Its action handlers
        // do not guard the live delegate's form manager after a state change.
        // Close stale offers as ignored, without calling those handlers.
        if (!delegate || delegate->GetState() != state) choice = 3;
        if (choice == 0) controller->OnSaveClicked();
        else if (choice == 1 && !controller->IsCurrentStateUpdate())
          controller->OnNeverForThisSiteClicked();
        else if (choice == 2) {
          if (controller->IsCurrentStateUpdate()) controller->OnNoThanksClicked();
          else controller->OnNotNowClicked();
        }
        controller->OnBubbleClosing();
      }, std::move(controller), delegate, state);
  CefRefPtr<OpenSavePrompt> prompt = new OpenSavePrompt(
      contents, state == password_manager::ui::PENDING_PASSWORD_STATE ? 0 : 1,
      user_action, std::move(answer));
  prompt->SetLabels(username, {}, {});
  ShowSavePrompt(prompt);
  return true;
}
bool OpenPasswordPromptRouter::Hide(content::WebContents* contents) {
  if (!IsOpenWebContents(contents)) return false;
  WithdrawSavePrompt(contents);
  return true;
}
}  // namespace open_engine
