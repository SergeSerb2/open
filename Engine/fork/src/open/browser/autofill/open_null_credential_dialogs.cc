// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#include "open/browser/autofill/open_autofill_hooks.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/ui/passwords/credential_manager_dialog_controller.h"
#include "chrome/browser/ui/passwords/credential_leak_dialog_controller.h"
#include "components/autofill/core/browser/ui/payments/card_unmask_prompt_controller.h"
#include "components/autofill/core/browser/ui/payments/autofill_error_dialog_controller.h"

namespace open_engine {
namespace {
// Owned by the controller. ControllerGone and destruction both cancel the
// posted close. No dialog or Views widget is created.
class NullAccount final : public AccountChooserPrompt {
 public:
  explicit NullAccount(CredentialManagerDialogController* c) : controller_(c) {}
  void ShowAccountChooser() override {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&NullAccount::Close, weak_.GetWeakPtr()));
  }
  void ControllerGone() override { controller_ = nullptr; weak_.InvalidateWeakPtrs(); }
 private:
  void Close() {
    auto* controller = controller_.get();
    controller_ = nullptr;
    if (controller) controller->OnCloseDialog();
  }
  raw_ptr<CredentialManagerDialogController> controller_;
  base::WeakPtrFactory<NullAccount> weak_{this};
};
class NullAutoSignin final : public AutoSigninFirstRunPrompt {
 public:
  explicit NullAutoSignin(CredentialManagerDialogController* c) : controller_(c) {}
  void ShowAutoSigninPrompt() override {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&NullAutoSignin::Close, weak_.GetWeakPtr()));
  }
  void ControllerGone() override { controller_ = nullptr; weak_.InvalidateWeakPtrs(); }
 private:
  void Close() {
    auto* controller = controller_.get();
    controller_ = nullptr;
    if (controller) controller->OnCloseDialog();
  }
  raw_ptr<CredentialManagerDialogController> controller_;
  base::WeakPtrFactory<NullAutoSignin> weak_{this};
};
class NullLeak final : public CredentialLeakPrompt {
 public:
  explicit NullLeak(CredentialLeakDialogController* c) : controller_(c) {}
  void ShowCredentialLeakPrompt() override {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&NullLeak::Close, weak_.GetWeakPtr()));
  }
  views::Widget* GetWidgetForTesting() override { return nullptr; }
 private:
  void Close() {
    auto* controller = controller_.get();
    controller_ = nullptr;
    if (controller) controller->OnCloseDialog();
  }
  raw_ptr<CredentialLeakDialogController> controller_;
  base::WeakPtrFactory<NullLeak> weak_{this};
};
class NullUnmask final : public autofill::CardUnmaskPromptView {
 public:
  explicit NullUnmask(autofill::CardUnmaskPromptController* c) : controller_(c) {}
  void Show() override {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&NullUnmask::Close, weak_.GetWeakPtr()));
  }
  void ControllerGone() override { controller_ = nullptr; delete this; }
  void Dismiss() override { Close(); }
  void DisableAndWaitForVerification() override {}
  void GotVerificationResult(const std::u16string&, bool) override {}
 private:
  ~NullUnmask() override = default;
  void Close() {
    auto* controller = controller_.get();
    controller_ = nullptr;
    if (controller) controller->OnUnmaskDialogClosed();
    delete this;
  }
  raw_ptr<autofill::CardUnmaskPromptController> controller_;
  base::WeakPtrFactory<NullUnmask> weak_{this};
};
class NullError final : public autofill::AutofillErrorDialogView {
 public:
  explicit NullError(autofill::AutofillErrorDialogController* c)
      : controller_(c->GetWeakPtr()) {}
  base::WeakPtr<autofill::AutofillErrorDialogView> GetWeakPtr() override {
    return weak_.GetWeakPtr();
  }
  void Show() {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&NullError::Dismiss, weak_.GetWeakPtr()));
  }
  void Dismiss() override {
    auto controller = controller_;
    controller_.reset();
    if (controller) controller->OnDismissed();
    delete this;
  }
 private:
  base::WeakPtr<autofill::AutofillErrorDialogController> controller_;
  base::WeakPtrFactory<NullError> weak_{this};
};
}  // namespace
void InstallNullCredentialDialogHooks() {
  auto& hooks = GetAutofillHooks();
  hooks.account = [](CredentialManagerDialogController* c)
      -> std::unique_ptr<AccountChooserPrompt> { return std::make_unique<NullAccount>(c); };
  hooks.autosignin = [](CredentialManagerDialogController* c)
      -> std::unique_ptr<AutoSigninFirstRunPrompt> { return std::make_unique<NullAutoSignin>(c); };
  hooks.leak = [](CredentialLeakDialogController* c)
      -> std::unique_ptr<CredentialLeakPrompt> { return std::make_unique<NullLeak>(c); };
  hooks.unmask = [](autofill::CardUnmaskPromptController* c)
      -> autofill::CardUnmaskPromptView* { return new NullUnmask(c); };
  hooks.error = [](autofill::AutofillErrorDialogController* c)
      -> base::WeakPtr<autofill::AutofillErrorDialogView> {
    auto* dialog = new NullError(c);
    auto weak = dialog->GetWeakPtr();
    dialog->Show();
    return weak;
  };
}
}  // namespace open_engine
